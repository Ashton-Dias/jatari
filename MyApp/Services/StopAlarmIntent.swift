import AppIntents

/// Runs when the system alarm's Stop button is pressed. It opens the app so the phrase screen can take over;
/// the alarm keeps going (the app plays the sound itself and a backup alarm is armed) until the phrase is typed.
struct StopAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Alarm"
    static let openAppWhenRun = true

    @Parameter(title: "Alarm ID") var alarmID: String

    init() { alarmID = "" }
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        await RingCoordinator.shared.systemAlertStopped(alarmIDString: alarmID)
        return .result()
    }
}
