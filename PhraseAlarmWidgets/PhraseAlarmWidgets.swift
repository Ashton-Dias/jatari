import WidgetKit
import SwiftUI
import AlarmKit

/// Renders AlarmKit's Live Activity (Lock Screen / Dynamic Island) for alarms, including the snooze countdown.
@main
struct PhraseAlarmWidgets: WidgetBundle {
    var body: some Widget {
        AlarmLiveActivity()
    }
}

struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<PhraseAlarmMetadata>.self) { context in
            AlarmActivityView(context: context)
                .padding()
                .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(title(context), systemImage: "alarm.fill").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "alarm.fill").foregroundStyle(.orange)
            } compactTrailing: {
                CountdownText(state: context.state).frame(maxWidth: 60)
            } minimal: {
                Image(systemName: "alarm.fill").foregroundStyle(.orange)
            }
        }
    }

    private func title(_ context: ActivityViewContext<AlarmAttributes<PhraseAlarmMetadata>>) -> String {
        String(localized: context.attributes.presentation.alert.title)
    }
}

private struct AlarmActivityView: View {
    let context: ActivityViewContext<AlarmAttributes<PhraseAlarmMetadata>>

    var body: some View {
        HStack {
            Image(systemName: "alarm.fill").foregroundStyle(.orange)
            Text(String(localized: context.attributes.presentation.alert.title)).font(.headline)
            Spacer()
            CountdownText(state: context.state).font(.title2.monospacedDigit())
        }
        .foregroundStyle(.white)
    }
}

/// Shows the time left while an alarm is snoozing (counting down); empty otherwise.
private struct CountdownText: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
                .multilineTextAlignment(.trailing)
        default:
            EmptyView()
        }
    }
}
