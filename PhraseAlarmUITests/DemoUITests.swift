import XCTest

/// Drives the app through the README demo. Run it while the simulator records the screen (see `tools/record_demo.sh`).
///
/// This is not part of the normal test run: use `-only-testing:PhraseAlarmUITests` to run it and
/// `-skip-testing:PhraseAlarmUITests` to run the unit tests without it.
/// Any `-preview*` launch flag makes the app skip permission prompts and background sync, which keeps the recording clean.
final class DemoUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// Types in short bursts with a tiny pause between them, so live feedback is visible on screen.
    private func typeSlowly(_ text: String, into app: XCUIApplication, burst: Int = 3, gap: TimeInterval = 0.1) {
        var rest = Substring(text)
        while !rest.isEmpty {
            let chunk = rest.prefix(burst)
            app.typeText(String(chunk))
            rest = rest.dropFirst(burst)
            pause(gap)
        }
    }

    /// Segment 1: the list, then add a new phrase alarm.
    func testSegment1_AddAPhraseAlarm() {
        let app = XCUIApplication()
        app.launchArguments = ["-previewList"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Gratitude"].waitForExistence(timeout: 15))
        pause(1.6)

        app.buttons["Add alarm"].tap()
        XCTAssertTrue(app.navigationBars["New Alarm"].waitForExistence(timeout: 5))
        pause(0.8)

        for day in ["Monday", "Tuesday", "Wednesday"] {
            app.buttons[day].tap()
            pause(0.25)
        }
        pause(0.4)

        // A plain tap lands on the row's label; the switch itself sits at the right-hand end of the row.
        let toggle = app.switches["Require phrase to stop"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let phraseField = app.descendants(matching: .any)["phraseField"]
        XCTAssertTrue(phraseField.waitForExistence(timeout: 5))
        phraseField.tap()
        pause(0.4)
        typeSlowly("Wake up with gratitude", into: app, burst: 4, gap: 0.08)
        pause(0.8)

        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Gratitude"].waitForExistence(timeout: 5))
        pause(1.8)
    }

    /// Segment 2: the full-screen phrase screen, including a typo that shows red and is then corrected.
    func testSegment2_TypeThePhrase() {
        let app = XCUIApplication()
        app.launchArguments = ["-previewRinging"]
        app.launch()
        let prompt = app.staticTexts["Type this phrase to turn off the alarm"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        pause(1.3)

        typeSlowly("I am awake and gettinX", into: app, burst: 4, gap: 0.08)   // the last character is wrong: it turns red
        pause(0.9)
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        pause(0.4)
        typeSlowly("g out of bed", into: app, burst: 3, gap: 0.08)             // completing the phrase ends the alarm

        XCTAssertTrue(app.navigationBars["Gratitude"].waitForExistence(timeout: 10))
        pause(1.5)
    }
}
