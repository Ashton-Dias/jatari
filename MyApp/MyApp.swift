import SwiftUI
import SwiftData
import UserNotifications

@main struct MyApp: App {
    let container: ModelContainer

    init() {
        let container = try! ModelContainer(for: AlarmItem.self, CustomSound.self)
        self.container = container
        RingCoordinator.shared.container = container
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        AppAppearance.apply()
        SampleData.seedIfNeeded(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .font(.app(.body))
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}

/// Foreground / tapped alarm notifications (fallback path) hand control to the ring coordinator.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if isPhraseAlarm(notification) {
            handle(notification)
            return []      // the app plays the sound and shows the phrase screen itself
        }
        return [.banner, .list, .sound]   // normal alarm: show it, with its Snooze action
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == AlarmScheduler.snoozeActionID {
            AlarmScheduler.shared.snooze(response.notification)
        } else if isPhraseAlarm(response.notification) {
            handle(response.notification)
        }
    }

    private func isPhraseAlarm(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo["phrase"] as? Bool ?? false
    }

    private func handle(_ notification: UNNotification) {
        guard let s = notification.request.content.userInfo["alarmID"] as? String, let id = UUID(uuidString: s) else { return }
        RingCoordinator.shared.alarmAlerting(systemAlarmID: id, appPlaysSound: true)
    }
}

enum SampleData {
    private static let key = "didSeedSampleAlarms"

    static func seedIfNeeded(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let samples: [AlarmItem] = [
            // Phrase alarm: no snooze, needs the phrase. The other two are normal alarms (Stop + 3-minute Snooze).
            AlarmItem(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], label: "Weekday Wake-up",
                      soundID: "builtin:Radar", requiresPhrase: true, phrase: "I am awake and getting out of bed"),
            AlarmItem(hour: 9, minute: 0, weekdays: [1, 7], label: "Weekend", soundID: "builtin:GentleRise", isEnabled: false),
            AlarmItem(hour: 6, minute: 30, weekdays: [], label: "Early Flight", soundID: "builtin:Siren", isEnabled: false),
        ]
        samples.forEach(context.insert)
        try? context.save()
    }
}
