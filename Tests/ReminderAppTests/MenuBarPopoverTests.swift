import AppKit
import SwiftUI
import XCTest
@testable import ReminderApp
import ReminderCore

/// Where the menu bar popover lands.
///
/// A customer on 1.2.0 saw it open sometimes well below the menu bar, with a
/// gap, and sometimes tight against it with the top of its content (the
/// "Next up" header) cut off. These tests open the real popover under a
/// stand-in for the status item and check it lands, and stays, where it
/// should.
///
/// The popover has to be shown on screen to be placed, so these run only
/// with PAUSELET_VISUAL_TESTS=1.
@MainActor
final class MenuBarPopoverTests: XCTestCase {
    private var anchorWindow: NSWindow!
    private var anchor: NSView { anchorWindow.contentView! }

    override func setUp() async throws {
        try requireVisualTests()
        await MainActor.run {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            // A status-item-sized window at the top of the usable screen.
            let screen = NSScreen.main!.visibleFrame
            anchorWindow = NSWindow(
                contentRect: NSRect(x: screen.maxX - 300, y: screen.maxY - 22, width: 70, height: 22),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            anchorWindow.isReleasedWhenClosed = false
            anchorWindow.level = .statusBar
            anchorWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
            anchorWindow.orderFrontRegardless()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { anchorWindow?.orderOut(nil) }
    }

    private func engine(reminders: Int) -> ReminderEngine {
        let titles = ["Have a rest", "Drink Water", "Stretch & Range of Motion",
                      "Tilt Back", "Weight Shift", "Call Mum", "Walk"]
        let list = (0..<reminders).map { index in
            Reminder(
                title: titles[index % titles.count],
                schedule: .interval(minutes: 5 + index * 10),
                symbolName: "bell"
            )
        }
        return ReminderEngine(store: InMemoryDataStore(data: AppData(reminders: list)))
    }

    private func settle(_ seconds: TimeInterval = 0.8) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// What the popover looks like right now, measured.
    private struct Placement: CustomStringConvertible {
        /// Points between the anchor's bottom edge and the popover window's
        /// top edge (its arrow). Zero or near it when attached.
        let gap: CGFloat
        /// Points of the content view lying outside the popover's frame view,
        /// which draws the bubble — cut off on screen.
        let overflow: CGFloat
        /// The content's own height minus the height it was given: positive
        /// means it is squeezed (the header cut, as in the customer's other
        /// screenshot); negative, padded with an empty band.
        let squeeze: CGFloat
        let windowHeight: CGFloat
        var description: String {
            "gap \(gap), overflow \(overflow), squeeze \(squeeze), window \(windowHeight)"
        }
    }

    private func measure(_ popover: MenuBarPopover, file: StaticString = #filePath, line: UInt = #line) -> Placement? {
        guard let window = popover.hosting.view.window else {
            XCTFail("popover is not on screen", file: file, line: line)
            return nil
        }
        let view = popover.hosting.view
        let frame = view.frame
        let container = view.superview?.bounds ?? frame
        return Placement(
            gap: anchorWindow.frame.minY - window.frame.maxY,
            overflow: max(0, container.minY - frame.minY, frame.maxY - container.maxY),
            squeeze: view.fittingSize.height - frame.height,
            windowHeight: window.frame.height
        )
    }

    private func assertAttached(
        _ placement: Placement?, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let placement else { return }
        XCTAssertEqual(placement.gap, 0, accuracy: 2, "\(what): \(placement)", file: file, line: line)
        XCTAssertEqual(placement.overflow, 0, accuracy: 0.5, "\(what): content outside the popover: \(placement)", file: file, line: line)
        XCTAssertEqual(placement.squeeze, 0, accuracy: 1, "\(what): content not at its own height: \(placement)", file: file, line: line)
    }

    func testFirstOpenIsAttachedAndUnclipped() {
        let popover = MenuBarPopover(engine: engine(reminders: 5)) {}
        popover.show(below: anchor)
        settle()
        assertAttached(measure(popover), "first open")
        popover.close()
        settle(0.4)
    }

    func testReopeningLandsInTheSamePlace() {
        let popover = MenuBarPopover(engine: engine(reminders: 5)) {}
        popover.show(below: anchor)
        settle()
        let first = measure(popover)
        popover.close()
        settle(0.4)
        popover.show(below: anchor)
        settle()
        let second = measure(popover)
        assertAttached(second, "reopen")
        if let first, let second {
            XCTAssertEqual(first.gap, second.gap, accuracy: 0.5, "first \(first) vs reopen \(second)")
            XCTAssertEqual(first.windowHeight, second.windowHeight, accuracy: 0.5)
        }
        popover.close()
        settle(0.4)
    }

    /// The content changes while the popover is open: reminders come and go,
    /// and pausing swaps the header. It must stay attached throughout.
    func testStaysAttachedWhileContentChanges() {
        let engine = engine(reminders: 2)
        let popover = MenuBarPopover(engine: engine) {}
        popover.show(below: anchor)
        settle()
        assertAttached(measure(popover), "two reminders")

        for index in 0..<5 {
            engine.add(Reminder(title: "Added \(index)", schedule: .interval(minutes: 30), symbolName: "bell"))
        }
        settle()
        assertAttached(measure(popover), "seven reminders")

        engine.setPaused(true)
        settle()
        assertAttached(measure(popover), "paused")

        for reminder in engine.reminders { engine.delete(id: reminder.id) }
        settle()
        assertAttached(measure(popover), "empty")

        popover.close()
        settle(0.4)
    }
}
