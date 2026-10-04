import SwiftUI
import SwiftData
import AlarmKit

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var alarms: [AlarmItem]
    @Query private var sounds: [CustomSound]
    private let coordinator = RingCoordinator.shared

    var body: some View {
        AlarmListView()
            .fullScreenCover(isPresented: .constant(coordinator.ringingAlarmID != nil)) {
                RingingView()
            }
            .task {
                coordinator.restoreIfNeeded()
                if ProcessInfo.processInfo.arguments.contains("-previewRinging") {
                    try? await Task.sleep(for: .seconds(1))
                    if let first = alarms.first(where: \.isPhraseAlarm) { coordinator.alarmAlerting(systemAlarmID: first.id) }
                }
                // Screenshot/preview launches skip the system permission prompts.
                guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-preview") }) else { return }
                await AlarmScheduler.shared.sync(alarms: alarms, sounds: sounds)
            }
            .task {
                // Reflect system alarms that start alerting while the app is open.
                for await updated in AlarmManager.shared.alarmUpdates {
                    if let ringing = updated.first(where: { $0.state == .alerting }) {
                        coordinator.alarmAlerting(systemAlarmID: ringing.id)
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { coordinator.restoreIfNeeded() }
            }
    }
}
