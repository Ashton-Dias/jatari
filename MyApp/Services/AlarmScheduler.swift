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
///   after the phrase has been typed. Because Stop on a locked phone can't open the app, a chain of backup
///   alarms (one every `AlarmTiming.followUpSeconds`) is armed *before* the alarm fires, so Stop alone never ends it.
@MainActor
final class AlarmScheduler {
    static let shared = AlarmScheduler()
    private let manager = AlarmManager.shared
    private let defaults = UserDefaults.standard
    private let backupKey = "backupAlarmIDs"

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
        // Needed in both modes: the fallback uses it for the alarm itself, AlarmKit mode for the "unlock" prompt.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
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
            await armBackupChains(alarms: alarms, sounds: sounds)
            // Drop AlarmKit alarms that no longer correspond to a stored alarm.
            let known = Set(alarms.map(\.id)).union(backupIDs().values.flatMap { $0 })
            for existing in ((try? manager.alarms) ?? []) where !known.contains(existing.id) { try? manager.cancel(id: existing.id) }
        case .notifications:
            await syncNotifications(alarms: alarms, sounds: sounds)
        }
    }

    func cancel(_ alarm: AlarmItem) {
        try? manager.cancel(id: alarm.id)
        cancelBackups(for: alarm.id)
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

    // MARK: Backup chain

    /// Arms the backup chain for every enabled phrase alarm (from its next fire time) and removes stale chains.
    /// A phrase alarm that is ringing right now keeps its chain untouched.
    private func armBackupChains(alarms: [AlarmItem], sounds: [CustomSound]) async {
        let phraseAlarms = alarms.filter { $0.isEnabled && $0.isPhraseAlarm }
        let count = AlarmTiming.backupCount(forPhraseAlarms: phraseAlarms.count)
        for alarm in alarms where !(alarm.isEnabled && alarm.isPhraseAlarm) { cancelBackups(for: alarm.id) }
        for alarm in phraseAlarms {
            if isRinging(alarm) { continue }
            guard let fire = ScheduleLogic.nextFireDate(hour: alarm.hour, minute: alarm.minute,
                                                        weekdays: Set(alarm.weekdays), after: .now) else { continue }
            await armBackups(for: alarm, sounds: sounds, from: fire, count: count)
            scheduleUnlockNotification(for: alarm, at: fire)
        }
    }

    private func isRinging(_ alarm: AlarmItem) -> Bool {
        if RingCoordinator.shared.ringingAlarmID == alarm.id { return true }
        let ids = Set([alarm.id] + (backupIDs()[alarm.id] ?? []))
        return ((try? manager.alarms) ?? []).contains { ids.contains($0.id) && $0.state != .scheduled }
    }

    /// Replaces the alarm's backups with `count` fixed alarms, one every `followUpSeconds` after `base`.
    private func armBackups(for alarm: AlarmItem, sounds: [CustomSound], from base: Date, count: Int,
                            keeping extra: [UUID] = []) async {
        cancelBackups(for: alarm.id)
        var ids = extra
        for fire in ScheduleLogic.backupDates(from: base, count: count, interval: AlarmTiming.followUpSeconds) {
            let id = UUID()
            do {
                _ = try await manager.schedule(id: id, configuration: configuration(for: alarm, sounds: sounds, schedule: .fixed(fire)))
                ids.append(id)
                setBackupIDs(ids, for: alarm.id)
            } catch {
                print("AlarmKit backup failed: \(error)")
            }
        }
        setBackupIDs(ids, for: alarm.id)
    }

    /// Called when Stop is pressed: pushes the chain out from now, so another alarm always rings within
    /// `followUpSeconds`. It does not depend on the app being on screen, so a locked phone still gets it.
    func scheduleRearm(for alarm: AlarmItem, sounds: [CustomSound]) async {
        guard alarm.isPhraseAlarm else { return }   // normal alarms never re-arm
        let count = AlarmTiming.backupCount(forPhraseAlarms: 1)
        await armBackups(for: alarm, sounds: sounds, from: .now, count: count)
        postUnlockNotification(for: alarm, after: 2)
    }

    /// Cancels every backup (and a pending/alerting test alarm) for a stored alarm. Used when the phrase is solved,
    /// the alarm is deleted or disabled, or the chain is rebuilt.
    func cancelBackups(for alarmID: UUID) {
        var map = backupIDs()
        guard let ids = map.removeValue(forKey: alarmID) else { return }
        for id in ids { try? manager.stop(id: id); try? manager.cancel(id: id) }
        saveBackupIDs(map)
    }

    /// A system alarm that no longer has a stored alarm behind it (deleted while ringing / a backup was pending):
    /// silence and remove it so nothing is left ringing with no way to end it.
    func endOrphan(systemAlarmID: UUID) {
        try? manager.stop(id: systemAlarmID)
        try? manager.cancel(id: systemAlarmID)
        if let stored = storedAlarmID(forSystemAlarm: systemAlarmID), stored != systemAlarmID { cancelBackups(for: stored) }
    }

    func stopSystemAlert(for alarmID: UUID) {
        try? manager.stop(id: alarmID)
        for id in backupIDs()[alarmID] ?? [] { try? manager.stop(id: id) }
    }

    /// Maps an AlarmKit alarm id (main or backup) back to the stored alarm id.
    func storedAlarmID(forSystemAlarm id: UUID) -> UUID? {
        if let hit = backupIDs().first(where: { $0.value.contains(id) }) { return hit.key }
        return id
    }

    // MARK: Unlock prompt

    /// A visible, silent, time-sensitive prompt for the lock screen: the alarm can't open the app by itself there.
    private func unlockContent(for alarm: AlarmItem) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alarm.label.isEmpty ? "Alarm" : alarm.label
        content.body = "Unlock and type your phrase to turn this alarm off."
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["alarmID": alarm.id.uuidString, "unlock": true]
        return content
    }

    private func scheduleUnlockNotification(for alarm: AlarmItem, at fire: Date) {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        let request = UNNotificationRequest(identifier: "alarm.\(alarm.id.uuidString).unlock.\(Int(fire.timeIntervalSince1970))",
                                            content: unlockContent(for: alarm),
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    private func postUnlockNotification(for alarm: AlarmItem, after seconds: TimeInterval) {
        let request = UNNotificationRequest(identifier: "alarm.\(alarm.id.uuidString).unlock.stop.\(Int(Date().timeIntervalSince1970))",
                                            content: unlockContent(for: alarm),
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// Schedules a one-off alarm a few seconds from now, for trying the real ringing flow.
    func scheduleTest(for alarm: AlarmItem, sounds: [CustomSound], in seconds: TimeInterval = 10) async {
        await requestAuthorization()
        if mode == .alarmKit {
            let id = UUID()
            let fire = Date.now.addingTimeInterval(seconds)
            _ = try? await manager.schedule(id: id, configuration: configuration(for: alarm, sounds: sounds, schedule: .fixed(fire)))
            if alarm.isPhraseAlarm {
                // The test alarm is tracked with its backups, so solving the phrase cancels all of them.
                await armBackups(for: alarm, sounds: sounds, from: fire,
                                 count: AlarmTiming.backupCount(forPhraseAlarms: 1), keeping: [id])
            }
        } else {
            await postNotificationChain(for: alarm, soundFile: SoundLibrary.fileName(for: alarm.soundID, customSounds: sounds),
                                        start: .now.addingTimeInterval(seconds), tag: "test", length: alarm.isPhraseAlarm ? 10 : 1)
        }
    }

    private func backupIDs() -> [UUID: [UUID]] {
        let raw = defaults.dictionary(forKey: backupKey) as? [String: [String]] ?? [:]
        return raw.reduce(into: [:]) { if let k = UUID(uuidString: $1.key) { $0[k] = $1.value.compactMap(UUID.init(uuidString:)) } }
    }
    private func saveBackupIDs(_ map: [UUID: [UUID]]) {
        defaults.set(map.reduce(into: [String: [String]]()) { $0[$1.key.uuidString] = $1.value.map(\.uuidString) }, forKey: backupKey)
    }
    private func setBackupIDs(_ ids: [UUID], for alarmID: UUID) {
        var map = backupIDs(); map[alarmID] = ids; saveBackupIDs(map)
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
