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
        let title = app.textFields["editorTitle"]
        title.tap()
        title.typeText("Morning physio")
        // Put the keyboard away before presenting anything else: a nested
        // sheet presented over a live keyboard dismisses the editor itself.
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists { returnKey.tap() } else { app.keyboards.buttons["return"].tap() }
        app.segmentedControls["editorType"].buttons["Exercise"].tap()
        XCTAssertTrue(app.textFields["Exercise name"].firstMatch.waitForExistence(timeout: 5))

        // Fill the programme through Import from Text rather than typing six
        // fields per row: the importer replaces the blank seeded row, and the
        // sheet with its parsed rows is a screenshot in its own right.
        let importButton = app.buttons["editorImportExercises"]
        scrollIntoView(importButton, in: app)
        importButton.tap()
        // A vertical-axis TextField is exposed as a text view, so match the
        // identifier on any element type.
        let importText = app.descendants(matching: .any)["importText"]
        if !importText.waitForExistence(timeout: 5) {
            snap("diag-after-import-tap", to: outDir)
            let ids = app.descendants(matching: .any).allElementsBoundByIndex
                .map { "\($0.elementType.rawValue):\($0.identifier)/\($0.label)" }
                .filter { !$0.hasSuffix(":/") }
            print("DIAG-ELEMENTS: \(ids.prefix(60))")
            XCTFail("import sheet did not open")
        }
        importText.tap()
        importText.typeText(
            "2 sets of 10 shoulder shrugs, holding for 5 seconds. "
            + "Then neck rotations: 1 set of 20 each side. "
            + "Finally, hamstring stretches: 1 set of 10 reps, holding for 30 seconds."
        )
        app.buttons["importReadText"].tap()
        let importAdd = app.buttons["importAdd"]
        XCTAssertTrue(importAdd.waitForExistence(timeout: 5))
        sleep(1)
        snap("02c-import-parsed", to: outDir)
        importAdd.tap()
        sleep(1)
        snap("02b-editor-exercise", to: outDir)
        // Typing left the keyboard up and Preview below it. Scrolling the form
        // dismisses the keyboard; keep going until the button's frame is
        // inside the window (isHittable throws for off-screen elements on
        // iPad), then let the scroll settle before tapping.
        let preview = app.buttons["editorPreview"]
        scrollIntoView(preview, in: app)
        preview.tap()
        XCTAssertTrue(app.buttons["takeoverDone"].waitForExistence(timeout: 10))
        snap("06-takeover-exercise", to: outDir)
        app.buttons["takeoverSnooze"].tap()
        // Dismissing the preview's full-screen cover takes the editor sheet
        // with it; only tap Cancel if the sheet is still there.
        let editorCancel = app.buttons["Cancel"].firstMatch
        if editorCancel.waitForExistence(timeout: 3) {
            editorCancel.tap()
        }

        openTab("History", in: app)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        snap("03-history", to: outDir)

        openTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snap("04-settings", to: outDir)

        openTab("About", in: app)
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        snap("05-about", to: outDir)
    }

    /// Swipes the form up until the element's frame sits comfortably inside
    /// the window, then lets the scroll settle. `isHittable` throws for
    /// off-screen elements on iPad, so this goes by frame instead.
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        var swipes = 0
        while swipes < 8 {
            if element.exists {
                let f = element.frame
                if f.minY > window.minY + 120, f.maxY < window.maxY - 120 { break }
            }
            app.swipeUp()
            swipes += 1
        }
        sleep(1)
    }

    /// iPhone puts the tabs in a bottom tab bar; iPadOS 26 renders the same
    /// TabView as a top bar or sidebar with no TabBar element, so fall back to
    /// any button carrying the tab's label.
    private func openTab(_ name: String, in app: XCUIApplication) {
        let inBar = app.tabBars.buttons[name]
        if inBar.exists { inBar.tap(); return }
        let anywhere = app.buttons[name].firstMatch
        XCTAssertTrue(anywhere.waitForExistence(timeout: 5), "No tab named \(name)")
        anywhere.tap()
    }

    private func snap(_ name: String, to dir: URL) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
