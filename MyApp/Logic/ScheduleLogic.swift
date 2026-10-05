import Foundation

/// Pure scheduling helpers (no UI / framework state) so they can be unit tested.
nonisolated enum ScheduleLogic {
    /// Calendar weekday numbers: 1 = Sunday … 7 = Saturday.
    static let allWeekdays = Array(1...7)

    /// The next time an alarm with the given time and repeat days fires strictly after `date`.
    /// An empty `weekdays` set means "one time": the next occurrence of that clock time.
    static func nextFireDate(hour: Int, minute: Int, weekdays: Set<Int>,
                             after date: Date, calendar: Calendar = .current) -> Date? {
        var comps = DateComponents(); comps.hour = hour; comps.minute = minute; comps.second = 0
        if weekdays.isEmpty {
            return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
        }
        return weekdays.compactMap { day -> Date? in
            var c = comps; c.weekday = day
            return calendar.nextDate(after: date, matching: c, matchingPolicy: .nextTime)
        }.min()
    }

    /// Fire times of a phrase alarm's backup chain: `count` dates, one every `interval` seconds after `base`.
    static func backupDates(from base: Date, count: Int, interval: TimeInterval) -> [Date] {
        guard count > 0 else { return [] }
        return (1...count).map { base.addingTimeInterval(Double($0) * interval) }
    }

    static func repeatSummary(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        if weekdays.isEmpty { return "Once" }
        if weekdays.count == 7 { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        let symbols = calendar.shortWeekdaySymbols
        return weekdays.sorted().map { symbols[$0 - 1] }.joined(separator: " ")
    }
}

/// Decides whether typed text satisfies the dismissal phrase.
nonisolated enum PhraseMatcher {
    static let minimumLength = 8

    static func isValidPhrase(_ phrase: String) -> Bool {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength
    }

    /// Trims, collapses runs of whitespace, and (unless strict) ignores case.
    static func normalize(_ s: String, strict: Bool) -> String {
        let collapsed = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return strict ? collapsed : collapsed.lowercased()
    }

    static func matches(typed: String, phrase: String, strict: Bool) -> Bool {
        let target = normalize(phrase, strict: strict)
        return !target.isEmpty && normalize(typed, strict: strict) == target
    }

    enum CharState { case correct, wrong, pending }

    /// Per-character feedback for the phrase being typed, aligned to the phrase's characters.
    static func feedback(typed: String, phrase: String, strict: Bool) -> [(Character, CharState)] {
        let typedChars = Array(strict ? typed : typed.lowercased())
        return phrase.enumerated().map { i, ch in
            guard i < typedChars.count else { return (ch, .pending) }
            let expected = strict ? ch : Character(String(ch).lowercased())
            return (ch, typedChars[i] == expected ? .correct : .wrong)
        }
    }
}
