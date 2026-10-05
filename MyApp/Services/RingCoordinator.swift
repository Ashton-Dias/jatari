import Foundation
import SwiftData
import AVFoundation
import AlarmKit
import Observation

/// Owns the "a phrase alarm is ringing" state: which alarm, who is making noise, and how it ends.
///
/// Only phrase alarms use this. Normal alarms are handled entirely by the system alert (Stop / Snooze).
@MainActor
@Observable
final class RingCoordinator {
    static let shared = RingCoordinator()

    private(set) var ringingAlarmID: UUID?
    /// When true the app itself is looping the alarm sound (system alert already stopped or never existed).
    private(set) var appOwnsAudio = false

    var container: ModelContainer?
    private var player: AVAudioPlayer?
    private let defaultsKey = "ringingAlarmID"

    var ringingAlarm: AlarmItem? {
        guard let id = ringingAlarmID else { return nil }
        return storedAlarm(id)
    }

    private func storedAlarm(_ id: UUID) -> AlarmItem? {
        guard let context = container?.mainContext else { return nil }
        return try? context.fetch(FetchDescriptor<AlarmItem>(predicate: #Predicate { $0.id == id })).first
    }

    /// Restores state if the app was killed while a phrase alarm was still unresolved.
    func restoreIfNeeded() {
        guard ringingAlarmID == nil, let s = UserDefaults.standard.string(forKey: defaultsKey), let id = UUID(uuidString: s) else { return }
        if storedAlarm(id)?.isPhraseAlarm == true {
            ringingAlarmID = id
            startAppAudio()
        } else {
            clear()   // the alarm was deleted or is no longer a phrase alarm: nothing to solve
        }
    }

    /// Picks up a phrase alarm that is alerting right now but whose Stop intent never ran (for example Stop was
    /// slid on a locked phone), so unlocking lands on the phrase screen.
    func checkSystemAlerts() {
        for alarm in (try? AlarmManager.shared.alarms) ?? [] where alarm.state == .alerting {
            alarmAlerting(systemAlarmID: alarm.id)
        }
    }

    /// AlarmKit (or a notification) reports an alarm is alerting.
    /// - Phrase alarm: show the phrase screen (the system is making the noise unless `appPlaysSound`).
    /// - Normal alarm: nothing to do except tidy up a one-time alarm, since the system alert handles Stop/Snooze.
    /// - No stored alarm (deleted while ringing / a backup was pending): end it cleanly, never trap the user.
    func alarmAlerting(systemAlarmID: UUID, appPlaysSound: Bool = false) {
        let id = AlarmScheduler.shared.storedAlarmID(forSystemAlarm: systemAlarmID) ?? systemAlarmID
        guard let alarm = storedAlarm(id) else {
            AlarmScheduler.shared.endOrphan(systemAlarmID: systemAlarmID)
            if ringingAlarmID == id { stopAppAudio(); clear() }
            return
        }
        guard alarm.isPhraseAlarm else {
            if alarm.weekdays.isEmpty && alarm.isEnabled {
                alarm.isEnabled = false      // a one-time alarm has now fired; show it as off
                try? container?.mainContext.save()
            }
            return
        }
        guard ringingAlarmID != id else { return }
        begin(id)
        if appPlaysSound { startAppAudio() }
    }

    /// Stop was pressed on a phrase alarm's system alert. Keep ringing from inside the app and arm a backup.
    func systemAlertStopped(alarmIDString: String) async {
        guard let id = UUID(uuidString: alarmIDString) else { return }
        guard let alarm = storedAlarm(id), alarm.isPhraseAlarm else {
            AlarmScheduler.shared.endOrphan(systemAlarmID: id)
            return
        }
        // Arm the backup first: while locked the app may never get to show UI or start audio.
        begin(id)
        await AlarmScheduler.shared.scheduleRearm(for: alarm, sounds: sounds())
        startAppAudio()
    }

    /// The phrase was typed correctly (or there is nothing left to solve): end everything for good.
    func dismiss() {
        guard let id = ringingAlarmID else { return }
        stopAppAudio()
        let scheduler = AlarmScheduler.shared
        scheduler.stopSystemAlert(for: id)
        scheduler.cancelBackups(for: id)
        scheduler.clearNotifications(for: id)
        if let alarm = ringingAlarm {
            if alarm.weekdays.isEmpty { alarm.isEnabled = false; scheduler.cancel(alarm) }
            try? container?.mainContext.save()
        }
        clear()
        // Re-arm the next occurrence's backup chain / notification chains.
        if let context = container?.mainContext {
            Task { await scheduler.sync(alarms: (try? context.fetch(FetchDescriptor<AlarmItem>())) ?? [], sounds: sounds()) }
        }
    }

    // MARK: Private

    private func begin(_ id: UUID) {
        ringingAlarmID = id
        UserDefaults.standard.set(id.uuidString, forKey: defaultsKey)
    }

    private func clear() {
        ringingAlarmID = nil
        appOwnsAudio = false
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func sounds() -> [CustomSound] {
        (try? container?.mainContext.fetch(FetchDescriptor<CustomSound>())) ?? []
    }

    func startAppAudio() {
        guard player?.isPlaying != true else { return }
        let url = ringingAlarm.flatMap { SoundLibrary.url(for: $0.soundID, customSounds: sounds()) }
            ?? SoundLibrary.builtIns.first.flatMap { Bundle.main.url(forResource: $0.key, withExtension: "caf") }
        guard let url else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 1
            p.play()
            player = p
            appOwnsAudio = true
        } catch {
            print("Could not play alarm audio: \(error)")
        }
    }

    private func stopAppAudio() {
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
