import Testing
import Foundation
import SwiftData
@testable import MyApp

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}()
/// Keeps the tests' in-memory stores alive for the duration of the run.
private var retainedContainers: [ModelContainer] = []

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
private func parts(_ d: Date) -> DateComponents { utc.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d) }

struct NextFireDateTests {
    @Test func oneTimeLaterToday() {
        let next = ScheduleLogic.nextFireDate(hour: 7, minute: 30, weekdays: [], after: date(2026, 10, 7, 6, 0), calendar: utc)!
        #expect(parts(next).day == 7 && parts(next).hour == 7 && parts(next).minute == 30)
    }

    @Test func oneTimeAlreadyPassedRollsToTomorrow() {
        let next = ScheduleLogic.nextFireDate(hour: 7, minute: 30, weekdays: [], after: date(2026, 10, 7, 8, 0), calendar: utc)!
        #expect(parts(next).day == 8)
    }

    @Test func exactlyNowIsNotTheNextFire() {
        let now = date(2026, 10, 7, 7, 30)
        let next = ScheduleLogic.nextFireDate(hour: 7, minute: 30, weekdays: [], after: now, calendar: utc)!
        #expect(next > now && parts(next).day == 8)
    }

    @Test func repeatDaysPickNearestWeekday() {
        // 2026-10-07 is a Wednesday (4). Mon/Fri alarm -> Friday the 9th.
        let next = ScheduleLogic.nextFireDate(hour: 7, minute: 0, weekdays: [2, 6], after: date(2026, 10, 7, 12, 0), calendar: utc)!
        #expect(parts(next).weekday == 6 && parts(next).day == 9)
    }

    @Test func repeatDayTodayButPassedGoesToNextWeek() {
        let next = ScheduleLogic.nextFireDate(hour: 7, minute: 0, weekdays: [4], after: date(2026, 10, 7, 12, 0), calendar: utc)!
        #expect(parts(next).day == 14 && parts(next).weekday == 4)
    }

    @Test func repeatDayTodayStillAheadFiresToday() {
        let next = ScheduleLogic.nextFireDate(hour: 18, minute: 0, weekdays: [4], after: date(2026, 10, 7, 12, 0), calendar: utc)!
        #expect(parts(next).day == 7)
    }

    @Test func weekendsWrapOverTheWeek() {
        let next = ScheduleLogic.nextFireDate(hour: 9, minute: 0, weekdays: [1, 7], after: date(2026, 10, 7, 12, 0), calendar: utc)!
        #expect(parts(next).weekday == 7 && parts(next).day == 10)
    }

    @Test func repeatSummaries() {
        #expect(ScheduleLogic.repeatSummary([]) == "Once")
        #expect(ScheduleLogic.repeatSummary(Set(1...7)) == "Every day")
        #expect(ScheduleLogic.repeatSummary([2, 3, 4, 5, 6]) == "Weekdays")
        #expect(ScheduleLogic.repeatSummary([1, 7]) == "Weekends")
        #expect(ScheduleLogic.repeatSummary([2, 4], calendar: utc) == "Mon Wed")
    }
}

struct PhraseMatcherTests {
    let phrase = "I am awake and getting out of bed"

    @Test func typographicPunctuationMatchesPlain() {
        #expect(PhraseMatcher.matches(typed: "I'm awake now", phrase: "I\u{2019}m awake now", strict: true))
        #expect(PhraseMatcher.matches(typed: "I\u{2019}m awake now", phrase: "I'm awake now", strict: true))
        #expect(PhraseMatcher.matches(typed: "say \"hi\" - ok", phrase: "say \u{201C}hi\u{201D} \u{2014} ok", strict: true))
        #expect(!PhraseMatcher.matches(typed: "Im awake now", phrase: "I\u{2019}m awake now", strict: true))
    }

    @Test func feedbackTreatsCurlyApostropheAsCorrect() {
        let fb = PhraseMatcher.feedback(typed: "I'm", phrase: "I\u{2019}m up", strict: true)
        #expect(fb.prefix(3).allSatisfy { $0.1 == .correct })
    }

    @Test func accentedLettersMatchAcrossUnicodeForms() {
        #expect(PhraseMatcher.matches(typed: "cafe\u{301} time", phrase: "caf\u{E9} time", strict: true))
    }

    @Test func exactMatchAndCaseInsensitive() {
        #expect(PhraseMatcher.matches(typed: phrase, phrase: phrase, strict: false))
        #expect(PhraseMatcher.matches(typed: phrase.uppercased(), phrase: phrase, strict: false))
    }

    @Test func strictModeRespectsCase() {
        #expect(!PhraseMatcher.matches(typed: phrase.lowercased(), phrase: phrase, strict: true))
        #expect(PhraseMatcher.matches(typed: phrase, phrase: phrase, strict: true))
    }

    @Test func whitespaceIsTrimmedAndCollapsed() {
        #expect(PhraseMatcher.matches(typed: "  I am  awake and getting out of bed \n", phrase: phrase, strict: true))
    }

    @Test func partialOrWrongTextDoesNotMatch() {
        #expect(!PhraseMatcher.matches(typed: "I am awake", phrase: phrase, strict: false))
        #expect(!PhraseMatcher.matches(typed: phrase + "!", phrase: phrase, strict: false))
        #expect(!PhraseMatcher.matches(typed: "", phrase: phrase, strict: false))
    }

    @Test func emptyPhraseNeverMatches() {
        #expect(!PhraseMatcher.matches(typed: "", phrase: "", strict: false))
        #expect(!PhraseMatcher.matches(typed: "   ", phrase: "   ", strict: false))
    }

    @Test func phraseValidationMinimumLength() {
        #expect(!PhraseMatcher.isValidPhrase("short"))
        #expect(!PhraseMatcher.isValidPhrase("   1234567   "))
        #expect(PhraseMatcher.isValidPhrase("12345678"))
    }

    @Test func perCharacterFeedback() {
        let fb = PhraseMatcher.feedback(typed: "i amX", phrase: "I am up", strict: false)
        #expect(fb.map(\.1) == [.correct, .correct, .correct, .correct, .wrong, .pending, .pending])
        let strictFB = PhraseMatcher.feedback(typed: "i", phrase: "I am", strict: true)
        #expect(strictFB[0].1 == .wrong)
    }
}

@MainActor
struct AlarmModelTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: AlarmItem.self, CustomSound.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        retainedContainers.append(container)   // a context doesn't keep its container alive
        return ModelContext(container)
    }

    @Test func phraseOnlyAppliesWhenRequiredAndValid() {
        // Not required: a stored phrase is ignored, and there is no default phrase to fall back to.
        let a = AlarmItem(hour: 7, minute: 0, requiresPhrase: false, phrase: "I am awake and getting out of bed")
        #expect(a.phraseToType == nil)
        #expect(!a.isPhraseAlarm)
        // Required but too short: still not a phrase alarm (the editor won't let this be saved).
        let b = AlarmItem(hour: 7, minute: 0, requiresPhrase: true, phrase: "hi")
        #expect(b.phraseToType == nil)
        #expect(!b.isPhraseAlarm)
        // Required and valid: the trimmed phrase.
        let c = AlarmItem(hour: 7, minute: 0, requiresPhrase: true, phrase: "  Wake up now please ")
        #expect(c.phraseToType == "Wake up now please")
        #expect(c.isPhraseAlarm)
    }

    @Test func snoozeIsThreeMinutes() {
        #expect(AlarmTiming.snoozeSeconds == 180)
    }

    @Test func editingAnAlarmChangesItsNextFireDate() throws {
        let ctx = try makeContext()
        let alarm = AlarmItem(hour: 7, minute: 0, weekdays: [2])
        ctx.insert(alarm); try ctx.save()
        let now = date(2026, 10, 7, 12, 0)
        let before = ScheduleLogic.nextFireDate(hour: alarm.hour, minute: alarm.minute, weekdays: Set(alarm.weekdays), after: now, calendar: utc)!
        alarm.hour = 20; alarm.weekdays = [4]
        try ctx.save()
        let after = ScheduleLogic.nextFireDate(hour: alarm.hour, minute: alarm.minute, weekdays: Set(alarm.weekdays), after: now, calendar: utc)!
        #expect(before != after)
        #expect(parts(after).day == 7 && parts(after).hour == 20)
    }

    @Test func deletedAlarmsAreGone() throws {
        let ctx = try makeContext()
        let a = AlarmItem(hour: 7, minute: 0), b = AlarmItem(hour: 8, minute: 0)
        ctx.insert(a); ctx.insert(b); try ctx.save()
        ctx.delete(a); try ctx.save()
        let remaining = try ctx.fetch(FetchDescriptor<AlarmItem>())
        #expect(remaining.map(\.id) == [b.id])
    }

    @Test func seededSamplesIncludeDisabledWeekend() throws {
        // A throwaway defaults suite: tests run inside the app process and must not touch the app's own flag.
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ctx = try makeContext()
        SampleData.seedIfNeeded(in: ctx, defaults: defaults)
        SampleData.seedIfNeeded(in: ctx, defaults: defaults)   // second call must not seed again
        let alarms = try ctx.fetch(FetchDescriptor<AlarmItem>())
        #expect(alarms.count == 3)
        #expect(alarms.contains { $0.label == "Weekend" && !$0.isEnabled })
        #expect(alarms.filter(\.isPhraseAlarm).map(\.label) == ["Weekday Wake-up"])   // the other two are normal alarms
    }

    @Test func everyBuiltInSoundIsBundledAndShortEnough() throws {
        for sound in SoundLibrary.builtIns {
            let url = try #require(Bundle.main.url(forResource: sound.key, withExtension: "caf"), "missing \(sound.key)")
            let file = try AVAudioFileProbe.duration(url)
            #expect(file <= SoundLibrary.maxDuration)
        }
    }
}

import AVFoundation
enum AVAudioFileProbe {
    static func duration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }
}

@MainActor
struct AlarmDeletionTests {
    private func makeContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: AlarmItem.self, CustomSound.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        retainedContainers.append(container)
        return container
    }

    private func makeContext() throws -> ModelContext { ModelContext(try makeContainer()) }

    @Test func deleteRemovesOnlyThatAlarm() throws {
        let ctx = try makeContext()
        let a = AlarmItem(hour: 7, minute: 0), b = AlarmItem(hour: 8, minute: 0)
        ctx.insert(a); ctx.insert(b); try ctx.save()
        let removed = AlarmStore.delete(a, in: ctx)
        #expect(removed)
        #expect(try ctx.fetch(FetchDescriptor<AlarmItem>()).map(\.id) == [b.id])
    }

    @Test func deletingTheLastAlarmLeavesNone() throws {
        let ctx = try makeContext()
        let a = AlarmItem(hour: 7, minute: 0)
        ctx.insert(a); try ctx.save()
        AlarmStore.delete(a, in: ctx)
        #expect(try ctx.fetch(FetchDescriptor<AlarmItem>()).isEmpty)
    }

    /// Runs `body` with the ring coordinator pointed at a throwaway store, then restores it.
    private func withCoordinator(_ container: ModelContainer, _ body: (RingCoordinator) throws -> Void) throws {
        let coordinator = RingCoordinator.shared
        let previous = coordinator.container
        coordinator.container = container
        defer { coordinator.dismiss(); coordinator.container = previous }
        try body(coordinator)
    }

    @Test func aRingingPhraseAlarmCannotBeDeleted() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let a = AlarmItem(hour: 7, minute: 0, requiresPhrase: true, phrase: "I am awake and up")
        ctx.insert(a); try ctx.save()
        try withCoordinator(container) { coordinator in
            coordinator.alarmAlerting(systemAlarmID: a.id)
            #expect(coordinator.ringingAlarmID == a.id)
            let removed = AlarmStore.delete(a, in: ctx)
            #expect(!removed)
            let remaining = try ctx.fetch(FetchDescriptor<AlarmItem>()).count
            #expect(remaining == 1)
        }
    }

    @Test func normalAlarmsNeverEnterThePhraseFlow() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let normal = AlarmItem(hour: 7, minute: 0, weekdays: [], requiresPhrase: false)
        let repeating = AlarmItem(hour: 8, minute: 0, weekdays: [2, 3], requiresPhrase: false)
        ctx.insert(normal); ctx.insert(repeating); try ctx.save()
        try withCoordinator(container) { coordinator in
            coordinator.alarmAlerting(systemAlarmID: normal.id)
            coordinator.alarmAlerting(systemAlarmID: repeating.id)
            #expect(coordinator.ringingAlarmID == nil)
        }
        #expect(normal.isEnabled == false)       // a one-time alarm shows as off once it has fired
        #expect(repeating.isEnabled == true)     // a repeating one stays on
    }

    @Test func aMissingAlarmEndsCleanlyInsteadOfTrappingTheUser() throws {
        let container = try makeContainer()
        try withCoordinator(container) { coordinator in
            coordinator.alarmAlerting(systemAlarmID: UUID())   // no stored alarm behind it (deleted while a backup was pending)
            #expect(coordinator.ringingAlarmID == nil)
        }
    }

    @Test func ringingStateIsDroppedWhenItsAlarmWasDeleted() throws {
        let container = try makeContainer(); let ctx = container.mainContext
        let a = AlarmItem(hour: 7, minute: 0, requiresPhrase: true, phrase: "I am awake and up")
        ctx.insert(a); try ctx.save()
        UserDefaults.standard.set(a.id.uuidString, forKey: "ringingAlarmID")   // as if the app was killed mid-ring
        ctx.delete(a); try ctx.save()
        try withCoordinator(container) { coordinator in
            coordinator.restoreIfNeeded()
            #expect(coordinator.ringingAlarmID == nil)
        }
        #expect(UserDefaults.standard.string(forKey: "ringingAlarmID") == nil)
    }
}

struct BackupChainTests {
    @Test func datesStartOneIntervalAfterBase() {
        let base = date(2026, 10, 7, 7, 0)
        let dates = ScheduleLogic.backupDates(from: base, count: 3, interval: 60)
        #expect(dates == [date(2026, 10, 7, 7, 1), date(2026, 10, 7, 7, 2), date(2026, 10, 7, 7, 3)])
    }

    @Test func zeroCountIsEmpty() {
        #expect(ScheduleLogic.backupDates(from: .now, count: 0, interval: 60).isEmpty)
    }

    @Test func countSharesTheBudgetAndStaysUseful() {
        #expect(AlarmTiming.backupCount(forPhraseAlarms: 0) == 10)
        #expect(AlarmTiming.backupCount(forPhraseAlarms: 1) == 10)
        #expect(AlarmTiming.backupCount(forPhraseAlarms: 8) == 6)
        #expect(AlarmTiming.backupCount(forPhraseAlarms: 100) == 2)
    }
}
