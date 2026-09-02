import XCTest

/// Smoke tests driving the real app in the simulator: launch, the four tabs,
/// and the add-reminder flow end to end.
final class PauseletUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        dismissSystemPermissionAlerts()
        return app
    }

    /// First launch on a fresh simulator raises the notification and alarm
    /// authorization prompts; grant them so they cannot block the test's taps.
    private func dismissSystemPermissionAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 3) {
                allow.tap()
            } else {
                break
            }
        }
    }

    func testLaunchShowsReminderListWithStarterSet() throws {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Pauselet"].waitForExistence(timeout: 10))
        // The starter set seeds a first launch; on any launch the header row
        // exists.
        XCTAssertTrue(app.staticTexts["Next up"].exists || app.staticTexts["Paused"].exists)
    }

    func testAllTabsOpen() throws {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Quiet Hours"].exists)

        app.tabBars.buttons["About"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pauselet"].exists)

        app.tabBars.buttons["Reminders"].tap()
        XCTAssertTrue(app.navigationBars["Pauselet"].waitForExistence(timeout: 5))
    }

    func testAddReminderFlow() throws {
        let app = launch()
        let add = app.buttons["addReminder"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let title = app.textFields["editorTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("UITest Reminder")

        let save = app.buttons["editorSave"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(
            app.staticTexts["UITest Reminder"].waitForExistence(timeout: 5),
            "The new reminder must appear in the list"
        )
    }

    func testEditorValidationDisablesSaveWithoutTitle() throws {
        let app = launch()
        let add = app.buttons["addReminder"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let save = app.buttons["editorSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Save must be disabled until a title exists")

        app.buttons["Cancel"].tap()
    }

    func testExerciseEditorRequiresANamedExercise() throws {
        let app = launch()
        let add = app.buttons["addReminder"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let title = app.textFields["editorTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Physio")

        let save = app.buttons["editorSave"]
        XCTAssertTrue(save.isEnabled, "A titled standard reminder saves")

        app.segmentedControls["editorType"].buttons["Exercise"].tap()
        XCTAssertFalse(
            save.isEnabled,
            "Switching to Exercise seeds one blank row, which must block Save until it is named"
        )

        let name = app.textFields["Exercise name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Squats")
        XCTAssertTrue(save.isEnabled, "A named exercise makes the reminder saveable")

        app.buttons["Cancel"].tap()
    }

    func testPauseMenuOffersDurations() throws {
        let app = launch()
        let pause = app.buttons["pauseMenu"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(
            app.buttons["Pause for 30 minutes"].waitForExistence(timeout: 5)
                || app.buttons["Resume"].waitForExistence(timeout: 2)
        )
        // Close the menu without changing state: tap far from the menu items,
        // which anchor near the leading toolbar button.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
    }
}
