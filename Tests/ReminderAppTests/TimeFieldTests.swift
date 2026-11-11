import AppKit
import SwiftUI
import XCTest
@testable import ReminderApp
import ReminderAI
import ReminderCore

/// The time controls in the reminder editor and in quiet hours.
///
/// A customer on 1.2.0 saw the colon ride above the digits, a field jump while
/// being typed in, and a focused field keep showing its old number after a
/// stepper click — which clicking away then wrote back. The hand-built field
/// behind all three was replaced with the native control; these tests hold
/// the line on each symptom.
@MainActor
final class TimeFieldTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var hour: Int
        @Published var minute: Int
        init(_ hour: Int, _ minute: Int) { self.hour = hour; self.minute = minute }
    }

    private struct Row: View {
        @ObservedObject var model: Model
        var body: some View {
            Form {
                Section("Schedule") {
                    TimeField("From", hour: $model.hour, minute: $model.minute)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func render(_ model: Model) -> (RenderedView, NSDatePicker) {
        let rendered = RenderedView(Row(model: model), size: NSSize(width: 470, height: 160))
        let pickers = rendered.views(of: NSDatePicker.self)
        XCTAssertEqual(pickers.count, 1)
        return (rendered, pickers[0])
    }

    private func key(_ code: UInt16, _ scalar: Int, in window: NSWindow) -> NSEvent {
        let characters = String(UnicodeScalar(scalar)!)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )!
    }

    private func shown(_ picker: NSDatePicker) -> (hour: Int, minute: Int) {
        TimeField.components(of: picker.dateValue)
    }

    // MARK: - Value

    func testEveryMinuteOfTheDayRoundTrips() {
        for hour in 0..<24 {
            for minute in 0..<60 {
                let parts = TimeField.components(of: TimeField.date(hour: hour, minute: minute))
                XCTAssertEqual(parts.hour, hour)
                XCTAssertEqual(parts.minute, minute)
            }
        }
    }

    func testShowsTheBoundTime() {
        let (_, picker) = render(Model(7, 25))
        XCTAssertEqual(shown(picker).hour, 7)
        XCTAssertEqual(shown(picker).minute, 25)
    }

    /// The reported bug: step while the field has focus. The control must
    /// show the new value, and leaving the field must not undo it.
    func testSteppingWhileFocusedShowsAndKeepsTheNewValue() {
        let model = Model(7, 25)
        let (rendered, picker) = render(model)
        XCTAssertTrue(rendered.window.makeFirstResponder(picker))
        picker.keyDown(with: key(126, NSUpArrowFunctionKey, in: rendered.window))
        rendered.settle()

        XCTAssertEqual(model.hour, 8, "the step reaches the reminder")
        XCTAssertEqual(shown(picker).hour, 8, "the field shows what was stepped to")

        rendered.window.makeFirstResponder(nil)
        rendered.settle()
        XCTAssertEqual(model.hour, 8, "leaving the field keeps the stepped value")
        XCTAssertEqual(model.minute, 25)
    }

    func testTypedHourIsApplied() {
        let model = Model(7, 25)
        let (rendered, picker) = render(model)
        rendered.window.makeFirstResponder(picker)
        picker.keyDown(with: key(25, Int(("9" as Character).asciiValue!), in: rendered.window))
        rendered.settle()
        rendered.window.makeFirstResponder(nil)
        rendered.settle()
        XCTAssertEqual(model.hour, 9)
        XCTAssertEqual(shown(picker).hour, 9)
    }

    /// The other reported bug: a field moved when it was clicked into.
    func testFocusingAndEditingDoesNotMoveTheControl() {
        let (rendered, picker) = render(Model(7, 25))
        let before = rendered.frame(of: picker)
        rendered.window.makeFirstResponder(picker)
        rendered.settle()
        XCTAssertEqual(rendered.frame(of: picker), before)
        picker.keyDown(with: key(125, NSDownArrowFunctionKey, in: rendered.window))
        rendered.settle()
        XCTAssertEqual(rendered.frame(of: picker), before)
    }

    // MARK: - Pixels

    /// Where the label, the digits and the row's separators actually land.
    private struct RowMeasure {
        let label: ClosedRange<CGFloat>
        let digits: ClosedRange<CGFloat>
        let picker: CGRect
    }

    /// The ink of a time control's digits: inside the control, clear of its
    /// bezel on every side and of the stepper on the right.
    private func digits(of picker: CGRect, in bitmap: Bitmap) -> ClosedRange<CGFloat>? {
        bitmap.inkExtent(in: CGRect(
            x: picker.minX + 6, y: picker.minY + 4,
            width: picker.width - 24, height: picker.height - 8
        ))
    }

    /// One device pixel: the most a line may be off before a careful eye
    /// sees it.
    private func onePixel(_ bitmap: Bitmap) -> CGFloat { 1 / bitmap.scale + 0.001 }

    private func assertRowsLineUp(
        _ rendered: RenderedView, name: String, labelLeft: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let bitmap = try rendered.capture()
        let pickers = rendered.views(of: NSDatePicker.self)
        XCTAssertFalse(pickers.isEmpty, file: file, line: line)
        var failed = false
        for picker in pickers.map(rendered.frame(of:)) {
            let band = CGRect(
                x: labelLeft, y: picker.minY - 4,
                width: picker.minX - 12 - labelLeft, height: picker.height + 8
            )
            guard let label = bitmap.inkExtent(in: band),
                  let digits = digits(of: picker, in: bitmap) else {
                XCTFail("\(name): nothing measurable at \(picker)", file: file, line: line)
                failed = true
                continue
            }
            // Same baseline: the bottoms of the label and the digits.
            if abs(label.upperBound - digits.upperBound) > onePixel(bitmap) {
                XCTFail(
                    "\(name): label baseline \(label.upperBound) vs digits "
                        + "\(digits.upperBound) for the control at y=\(picker.minY)",
                    file: file, line: line
                )
                failed = true
            }
            // The row's padding even above and below the control. The form
            // puts the label and the control on one text baseline, which
            // leaves the control's visible box about 1.25pt above the row's
            // geometric centre — native layout, and the same in every row.
            // The 1.2.0 bug was a different order of thing: reserved,
            // invisible stepper space pushed controls ~10pt off and opened a
            // gap above the row. Hence 2pt, measured on the visible bezel
            // (not the frame, which pads it for the focus ring).
            let bezelLines = bitmap.lineRows(in: CGRect(
                x: picker.minX + 10, y: picker.minY - 3, width: 20, height: picker.height + 6
            ))
            let separators = bitmap.lineRows(in: CGRect(
                x: picker.minX - 10, y: picker.minY - 40, width: 6, height: picker.height + 80
            ))
            if let top = bezelLines.min(), let bottom = bezelLines.max(),
               let above = separators.filter({ $0 < top }).max(),
               let below = separators.filter({ $0 > bottom }).min() {
                let bezelCentre = (top + bottom + 1 / bitmap.scale) / 2
                let offCentre = bezelCentre - (above + below) / 2
                if abs(offCentre) > 2 {
                    XCTFail(
                        "\(name): control at y=\(picker.minY) sits \(offCentre)pt "
                            + "off its row's centre (row \(above)–\(below))",
                        file: file, line: line
                    )
                    failed = true
                }
            } else {
                XCTFail("\(name): could not find the row around y=\(picker.minY)", file: file, line: line)
                failed = true
            }
        }
        if failed {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pauselet-\(name).png")
            bitmap.save(to: url)
            print("Saved the failing render to \(url.path)")
        }
    }

    private func editor(_ schedule: Schedule) -> some View {
        let engine = ReminderEngine(store: InMemoryDataStore())
        return ReminderEditor(reminder: Reminder(
            title: "Have a rest", schedule: schedule, symbolName: "eye"
        )) { _ in }
            .environmentObject(engine)
            .environmentObject(MusicPlayer())
            .environmentObject(AIImportController(
                secrets: InMemorySecretStore(),
                makeInterpreter: { _, _ in PreviewExerciseInterpreter() }
            ))
    }

    /// The customer's own case: Start and End at a set time, in both
    /// appearances.
    func testEditorStartAndEndRowsLineUp() throws {
        try requireVisualTests()
        let schedule = Schedule.timedInterval(
            minutes: 5, startHour: 7, startMinute: 25,
            endHour: 22, endMinute: 0, weekdays: [2, 3, 4, 5, 6]
        )
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let rendered = RenderedView(
                editor(schedule), size: NSSize(width: 470, height: 760), appearance: appearance
            )
            XCTAssertEqual(rendered.views(of: NSDatePicker.self).count, 2)
            try assertRowsLineUp(rendered, name: "editor-\(appearance.rawValue)", labelLeft: 24)
        }
    }

    func testEditorDailyRowLinesUp() throws {
        try requireVisualTests()
        let rendered = RenderedView(
            editor(.dailyAt(hour: 9, minute: 5, dayInterval: 1)), size: NSSize(width: 470, height: 760)
        )
        try assertRowsLineUp(rendered, name: "editor-daily", labelLeft: 24)
    }

    /// Quiet hours put two controls in one sentence: "From 22:00 to 07:00".
    /// The "to" between them must sit on the digits' baseline.
    func testQuietHoursSentenceLinesUp() throws {
        try requireVisualTests()
        let engine = ReminderEngine(store: InMemoryDataStore(data: AppData(
            settings: Settings(quietHours: QuietHours(isEnabled: true))
        )))
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let rendered = RenderedView(
                PreferencesTab()
                    .environmentObject(engine)
                    .environmentObject(MusicPlayer())
                    .environmentObject(SpeechCoach())
                    .environmentObject(AIImportController(secrets: InMemorySecretStore())),
                size: NSSize(width: 700, height: 220), appearance: appearance
            )
            let bitmap = try rendered.capture()
            let pickers = rendered.views(of: NSDatePicker.self).map(rendered.frame(of:))
                .sorted { $0.minX < $1.minX }
            XCTAssertEqual(pickers.count, 2)
            guard pickers.count == 2,
                  let to = bitmap.inkExtent(in: CGRect(
                      x: pickers[0].maxX + 2, y: pickers[0].minY - 4,
                      width: pickers[1].minX - pickers[0].maxX - 4, height: pickers[0].height + 8
                  )),
                  let first = digits(of: pickers[0], in: bitmap),
                  let second = digits(of: pickers[1], in: bitmap)
            else { return XCTFail("nothing measurable") }
            XCTAssertEqual(first.upperBound, second.upperBound, accuracy: onePixel(bitmap))
            XCTAssertEqual(to.upperBound, first.upperBound, accuracy: onePixel(bitmap),
                           "\"to\" on the digits' baseline (\(appearance.rawValue))")
        }
    }
}
