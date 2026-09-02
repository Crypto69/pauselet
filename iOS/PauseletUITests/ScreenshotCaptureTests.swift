import XCTest

/// Drives the app through its main screens and writes full-resolution PNGs to
/// the simulator's /tmp (which maps into the host's CoreSimulator container),
/// for visual review of layout.
///
/// Skipped unless `TEST_RUNNER_CAPTURE_SCREENSHOTS=1` is passed to xcodebuild,
/// so regular test runs stay fast.
final class ScreenshotCaptureTests: XCTestCase {

    func testCaptureMainScreens() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CAPTURE_SCREENSHOTS"] == "1",
            "Set TEST_RUNNER_CAPTURE_SCREENSHOTS=1 to capture"
        )

        let outDir = URL(fileURLWithPath: "/tmp/pauselet-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() } else { break }
        }

        XCTAssertTrue(app.navigationBars["Pauselet"].waitForExistence(timeout: 10))
        snap("01-reminders", to: outDir)

        app.buttons["addReminder"].tap()
        XCTAssertTrue(app.textFields["editorTitle"].waitForExistence(timeout: 5))
        snap("02-editor", to: outDir)

        // The exercise variant, and its takeover via Preview — which never
        // touches the engine, so Snooze here changes nothing.
        app.segmentedControls["editorType"].buttons["Exercise"].tap()
        let exerciseName = app.textFields["Exercise name"].firstMatch
        XCTAssertTrue(exerciseName.waitForExistence(timeout: 5))
        exerciseName.tap()
        exerciseName.typeText("Squats")
        snap("02b-editor-exercise", to: outDir)
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.buttons["takeoverDone"].waitForExistence(timeout: 5))
        snap("06-takeover-exercise", to: outDir)
        app.buttons["takeoverSnooze"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        snap("03-history", to: outDir)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snap("04-settings", to: outDir)

        app.tabBars.buttons["About"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        snap("05-about", to: outDir)
    }

    private func snap(_ name: String, to dir: URL) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
