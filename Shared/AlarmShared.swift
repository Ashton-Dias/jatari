import Foundation
import AlarmKit

/// Compiled into both the app and the widget extension, so the Live Activity can decode alarm attributes.
struct PhraseAlarmMetadata: AlarmMetadata {
    var alarmID: String
}

nonisolated enum AlarmTiming {
    /// Snooze length for normal (non-phrase) alarms: 3 minutes.
    static let snoozeSeconds: TimeInterval = 180
    /// Seconds between backup re-arms / follow-up notifications for a phrase alarm that hasn't been solved.
    static let followUpSeconds: TimeInterval = 60

    /// How many backup alarms to arm per phrase alarm, sharing the system's alarm budget between them.
    static func backupCount(forPhraseAlarms n: Int) -> Int { max(2, min(10, 48 / max(1, n))) }
}
