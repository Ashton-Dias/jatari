import Foundation
import SwiftUI
import SwiftData
import AlarmKit
import ActivityKit
import AppIntents
@preconcurrency import UserNotifications

/// Schedules alarms with AlarmKit (rings through silent mode / Focus). If the user denies AlarmKit
/// access, falls back to local notifications.
///
/// Two kinds of alarm:
/// - **Normal alarms** (`requiresPhrase` off): system alert with Stop and a 3-minute Snooze (AlarmKit countdown).
/// - **Phrase alarms**: no snooze at all. The only way to end one for good is `RingCoordinator.dismiss()`
///   after the phrase has been typed.
@MainActor
final class AlarmScheduler {
    static let shared = AlarmScheduler()
    private let manager = AlarmManager.shared
    private let defaults = UserDefaults.standard
    private let rearmKey = "rearmAlarmIDs"

    /// Notification action id for Snooze (normal alarms in the notification fallback).
    static let snoozeActionID = "SNOOZE"
    static let snoozeCategoryID = "ALARM_SNOOZE"

    enum Mode { case alarmKit, notifications }

    private(set) var mode: Mode = .alarmKit

    // MARK: Authorization

    @discardableResult
    func requestAuthorization() async -> Mode {
        registerNotificationCategories()
        switch manager.authorizationState {
        case .authorized: mode = .alarmKit
        case .notDetermined:
            let state = try? await manager.requestAuthorization()
            mode = state == .authorized ? .alarmKit : .notifications
        default: mode = .notifications
        }
        if mode == .notifications {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
        return mode
    }

    // MARK: Sync

    /// Makes the system's alarms match the stored ones. Safe to call repeatedly.
    func sync(alarms: [AlarmItem], sounds: [CustomSound]) async {
        await requestAuthorization()
        switch mode {
        case .alarmKit:
            clearNotifications(for: nil)
            for alarm in alarms { await scheduleAlarmKit(alarm, sounds: sounds) }
            // Drop AlarmKit alarms that no longer correspond to a stored alarm.
            let known = Set(alarms.map(\.id)).union(rearmIDs().values)
            for existing in ((try? manager.alarms) ?? []) where !known.contains(existing.id) { try? manager.cancel(id: existing.id) }
        case .notifications:
            await syncNotifications(alarms: alarms, sounds: sounds)
        }
    }

    func cancel(_ alarm: AlarmItem) {
        try? manager.cancel(id: alarm.id)
        cancelRearm(for: alarm.id)
        clearNotifications(for: alarm.id)
    }

    // MARK: AlarmKit

    private func configuration(for alarm: AlarmItem, sounds: [CustomSound], schedule: Alarm.Schedule)
        -> AlarmManager.AlarmConfiguration<PhraseAlarmMetadata> {
        let title = LocalizedStringResource(stringLiteral: alarm.label.isEmpty ? "Alarm" : alarm.label)
        let metadata = PhraseAlarmMetadata(alarmID: alarm.id.uuidString)
        let sound: AlertConfiguration.AlertSound = SoundLibrary.fileName(for: alarm.soundID, customSounds: sounds)
            .map { .named($0) } ?? .default

        if alarm.isPhraseAlarm {
            // No `secondaryButton`: there is nothing to tap except Stop, and Stop opens the app to the phrase screen.
            let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: .init(title: title)),
                                             metadata: metadata, tintColor: .orange)
            return .alarm(schedule: schedule, attributes: attributes,
                          stopIntent: StopAlarmIntent(alarmID: alarm.id.uuidString), sound: sound)
        }

        // Normal alarm: Stop ends it; Snooze re-rings after `AlarmTiming.snoozeSeconds` (AlarmKit's countdown behavior).
        let snooze = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let alert = AlarmPresentation.Alert(title: title, secondaryButton: snooze, secondaryButtonBehavior: .countdown)
        let presentation = AlarmPresentation(alert: alert, countdown: .init(title: title, pauseButton: nil))
        let attributes = AlarmAttributes(presentation: presentation, metadata: metadata, tintColor: .orange)
        return AlarmManager.AlarmConfiguration(
            countdownDuration: .init(preAlert: nil, postAlert: AlarmTiming.snoozeSeconds),
            schedule: schedule, attributes: attributes, sound: sound)
    }

    private func scheduleAlarmKit(_ alarm: AlarmItem, sounds: [CustomSound]) async {
        // Leave an alarm that is ringing or snoozing right now alone, so syncing (app launch, editing another alarm)
        // never cancels an in-flight snooze.
        if let live = ((try? manager.alarms) ?? []).first(where: { $0.id == alarm.id }), live.state != .scheduled { return }
        try? manager.cancel(id: alarm.id)
        guard alarm.isEnabled else { return }
        let weekdays = alarm.weekdays.compactMap(Self.localeWeekday)
        let recurrence: Alarm.Schedule.Relative.Recurrence = weekdays.isEmpty ? .never : .weekly(weekdays)
        let schedule = Alarm.Schedule.relative(.init(time: .init(hour: alarm.hour, minute: alarm.minute), repeats: recurrence))
        do {
            _ = try await manager.schedule(id: alarm.id, configuration: configuration(for: alarm, sounds: sounds, schedule: schedule))
        } catch {
            print("AlarmKit schedule failed for \(alarm.label): \(error)")
        }
    }

    /// Called when Stop is pressed: a backup alarm fires shortly after, so silencing the system alert
    /// can never end the alarm. It is cancelled only when the phrase is typed.
    func scheduleRearm(for alarm: AlarmItem, sounds: [CustomSound]) async {
        guard alarm.isPhraseAlarm else { return }   // normal alarms never re-arm
        var map = rearmIDs()
        let rearmID = map[alarm.id] ?? UUID()
        map[alarm.id] = rearmID
        saveRearmIDs(map)
        try? manager.cancel(id: rearmID)
        let fire = Date().addingTimeInterval(AlarmTiming.followUpSeconds)
        do {
            _ = try await manager.schedule(id: rearmID, configuration: configuration(for: alarm, sounds: sounds, schedule: .fixed(fire)))
        } catch {
            print("AlarmKit re-arm failed: \(error)")
        }
    }

    func cancelRearm(for alarmID: UUID) {
        var map = rearmIDs()
        guard let id = map.removeValue(forKey: alarmID) else { return }
        try? manager.stop(id: id)
        try? manager.cancel(id: id)
        saveRearmIDs(map)
    }

    /// A system alarm that no longer has a stored alarm behind it (deleted while ringing / a backup was pending):
    /// silence and remove it so nothing is left ringing with no way to end it.
    func endOrphan(systemAlarmID: UUID) {
        try? manager.stop(id: systemAlarmID)
        try? manager.cancel(id: systemAlarmID)
        if let stored = storedAlarmID(forSystemAlarm: systemAlarmID) { cancelRearm(for: stored) }
    }

    func stopSystemAlert(for alarmID: UUID) {
        try? manager.stop(id: alarmID)
        if let r = rearmIDs()[alarmID] { try? manager.stop(id: r) }
    }

    /// Maps an AlarmKit alarm id (main or re-arm) back to the stored alarm id.
    func storedAlarmID(forSystemAlarm id: UUID) -> UUID? {
        if let hit = rearmIDs().first(where: { $0.value == id }) { return hit.key }
        return id
    }

    /// Schedules a one-off alarm a few seconds from now, for trying the real ringing flow.
    func scheduleTest(for alarm: AlarmItem, sounds: [CustomSound], in seconds: TimeInterval = 10) async {
        await requestAuthorization()
        if mode == .alarmKit {
            let id = UUID()
            if alarm.isPhraseAlarm { var map = rearmIDs(); map[alarm.id] = id; saveRearmIDs(map) }
            _ = try? await manager.schedule(id: id, configuration: configuration(for: alarm, sounds: sounds, schedule: .fixed(.now.addingTimeInterval(seconds))))
        } else {
            await postNotificationChain(for: alarm, soundFile: SoundLibrary.fileName(for: alarm.soundID, customSounds: sounds),
                                        start: .now.addingTimeInterval(seconds), tag: "test", length: alarm.isPhraseAlarm ? 10 : 1)
        }
    }

    private func rearmIDs() -> [UUID: UUID] {
        let raw = defaults.dictionary(forKey: rearmKey) as? [String: String] ?? [:]
        return raw.reduce(into: [:]) { if let k = UUID(uuidString: $1.key), let v = UUID(uuidString: $1.value) { $0[k] = v } }
    }
    private func saveRearmIDs(_ map: [UUID: UUID]) {
        defaults.set(map.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value.uuidString }, forKey: rearmKey)
    }

    static func localeWeekday(_ n: Int) -> Locale.Weekday? {
        [1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday, 5: .thursday, 6: .friday, 7: .saturday][n]
    }

    // MARK: Notification fallback

    private func syncNotifications(alarms: [AlarmItem], sounds: [CustomSound]) async {
        clearNotifications(for: nil)
        for alarm in alarms where alarm.isEnabled {
            let days = Set(alarm.weekdays)
            // One request chain per upcoming occurrence (non-repeating triggers, refreshed whenever the app syncs).
            let occurrences: [Date] = days.isEmpty
                ? [ScheduleLogic.nextFireDate(hour: alarm.hour, minute: alarm.minute, weekdays: [], after: .now)].compactMap { $0 }
                : days.compactMap { ScheduleLogic.nextFireDate(hour: alarm.hour, minute: alarm.minute, weekdays: [$0], after: .now) }
            let chain = max(2, min(10, 56 / max(1, enabledOccurrenceCount(alarms))))
            for start in occurrences {
                await postNotificationChain(for: alarm, soundFile: SoundLibrary.fileName(for: alarm.soundID, customSounds: sounds),
                                            start: start, tag: "\(Int(start.timeIntervalSince1970))",
                                            length: alarm.isPhraseAlarm ? chain : 1)
            }
        }
    }

    private func enabledOccurrenceCount(_ alarms: [AlarmItem]) -> Int {
        alarms.filter { $0.isEnabled && $0.isPhraseAlarm }.reduce(0) { $0 + max(1, $1.weekdays.count) }
    }

    /// Phrase alarms post a chain of notifications (one every 60 s) until the phrase is typed.
    /// Normal alarms post one notification with a Snooze action.
    private func postNotificationChain(for alarm: AlarmItem, soundFile: String?, start: Date, tag: String, length: Int) async {
        let id = alarm.id
        for n in 0..<length {
            let content = UNMutableNotificationContent()
            content.title = alarm.label.isEmpty ? "Alarm" : alarm.label
            content.body = alarm.isPhraseAlarm ? "Open the app and type your phrase to turn this alarm off." : "Alarm"
            content.sound = soundFile.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .defaultCritical
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["alarmID": id.uuidString, "phrase": alarm.isPhraseAlarm]
            if !alarm.isPhraseAlarm { content.categoryIdentifier = Self.snoozeCategoryID }
            let fire = start.addingTimeInterval(Double(n) * AlarmTiming.followUpSeconds)
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            let request = UNNotificationRequest(identifier: "alarm.\(id.uuidString).\(tag).\(n)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Registers the Snooze action used by normal alarms in the notification fallback.
    func registerNotificationCategories() {
        let snooze = UNNotificationAction(identifier: Self.snoozeActionID, title: "Snooze", options: [])
        let category = UNNotificationCategory(identifier: Self.snoozeCategoryID, actions: [snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Snooze tapped on a normal alarm's notification: ring again after `AlarmTiming.snoozeSeconds`.
    func snooze(_ notification: UNNotification) {
        guard let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent else { return }
        let id = (content.userInfo["alarmID"] as? String) ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: "alarm.\(id).snooze.\(Int(Date().timeIntervalSince1970))", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: AlarmTiming.snoozeSeconds, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// Removes pending and delivered notifications for one alarm (or all alarms when nil; pending snoozes are kept then).
    func clearNotifications(for alarmID: UUID?) {
        let center = UNUserNotificationCenter.current()
        let prefix = alarmID.map { "alarm.\($0.uuidString)." } ?? "alarm."
        let keepSnoozes = alarmID == nil
        center.getPendingNotificationRequests { reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier)
                .filter { $0.hasPrefix(prefix) && !(keepSnoozes && $0.contains(".snooze.")) })
        }
        center.getDeliveredNotifications { delivered in
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}
