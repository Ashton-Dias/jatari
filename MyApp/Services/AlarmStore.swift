import Foundation
import SwiftData

/// The one place alarms are deleted and re-synced, so every UI path cleans up identically.
@MainActor
enum AlarmStore {
    /// Deletes an alarm and everything the system holds for it (AlarmKit alarm, backup re-arm alarm,
    /// fallback notifications). Returns false, and does nothing, if the alarm is ringing right now:
    /// it can only be ended by typing its phrase.
    @discardableResult
    static func delete(_ alarm: AlarmItem, in context: ModelContext,
                       coordinator: RingCoordinator? = nil,
                       scheduler: AlarmScheduler? = nil) -> Bool {
        let coordinator = coordinator ?? RingCoordinator.shared
        let scheduler = scheduler ?? AlarmScheduler.shared
        guard coordinator.ringingAlarmID != alarm.id else { return false }
        scheduler.cancel(alarm)
        context.delete(alarm)
        try? context.save()
        resync(in: context, scheduler: scheduler)
        return true
    }

    /// Makes the system's alarms match what is stored.
    static func resync(in context: ModelContext, scheduler: AlarmScheduler? = nil) {
        let scheduler = scheduler ?? AlarmScheduler.shared
        try? context.save()
        let alarms = (try? context.fetch(FetchDescriptor<AlarmItem>())) ?? []
        let sounds = (try? context.fetch(FetchDescriptor<CustomSound>())) ?? []
        Task { await scheduler.sync(alarms: alarms, sounds: sounds) }
    }
}
