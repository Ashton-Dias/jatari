import Foundation
import SwiftData

@Model
final class AlarmItem {
    @Attribute(.unique) var id: UUID
    var hour: Int
    var minute: Int
    /// Calendar weekday numbers (1 = Sunday). Empty = one-time alarm.
    var weekdays: [Int]
    var label: String
    var soundID: String
    var isEnabled: Bool
    var requiresPhrase: Bool
    var phrase: String
    var strictMatch: Bool
    var createdAt: Date

    init(hour: Int, minute: Int, weekdays: [Int] = [], label: String = "Alarm",
         soundID: String = SoundLibrary.defaultSoundID, isEnabled: Bool = true,
         requiresPhrase: Bool = false, phrase: String = "", strictMatch: Bool = false) {
        self.id = UUID()
        self.hour = hour; self.minute = minute; self.weekdays = weekdays
        self.label = label; self.soundID = soundID; self.isEnabled = isEnabled
        self.requiresPhrase = requiresPhrase; self.phrase = phrase; self.strictMatch = strictMatch
        self.createdAt = .now
    }

    /// The phrase the user must type to stop this alarm, or nil if it isn't a phrase alarm.
    /// There is no default phrase: an alarm only has a phrase challenge if the user turned it on and set a valid phrase.
    var phraseToType: String? {
        requiresPhrase && PhraseMatcher.isValidPhrase(phrase)
            ? phrase.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Phrase alarms have no snooze and need the phrase to stop. Everything else is a normal alarm with Stop and a 3-minute Snooze.
    var isPhraseAlarm: Bool { phraseToType != nil }

    var timeString: String {
        var c = DateComponents(); c.hour = hour; c.minute = minute
        let date = Calendar.current.date(from: c) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

@Model
final class CustomSound {
    @Attribute(.unique) var id: UUID
    var name: String
    var fileName: String
    var duration: Double
    var wasTrimmed: Bool

    init(name: String, fileName: String, duration: Double, wasTrimmed: Bool) {
        self.id = UUID(); self.name = name; self.fileName = fileName
        self.duration = duration; self.wasTrimmed = wasTrimmed
    }

    var soundID: String { "custom:\(id.uuidString)" }
}
