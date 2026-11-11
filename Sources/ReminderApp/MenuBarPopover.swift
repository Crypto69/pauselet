import AppKit
import SwiftUI
import ReminderCore

/// The popover under the menu bar icon: the `MenuBarView` in an `NSPopover`.
///
/// Its own type so a test can show it from a stand-in for the status item and
/// check where it lands (MenuBarPopoverTests).
///
/// The size has exactly one source: the SwiftUI content, reported through the
/// hosting controller's `preferredContentSize`, which `NSPopover` reads when
/// it places itself and follows, still anchored, when the content changes.
/// 1.2.0 also set a fixed `contentSize` of 380x520. The popover was placed
/// for that, then the hosting controller resized the window to the content's
/// real height (464pt with five reminders) — and a window keeps its bottom
/// edge when resized, so the top, arrow and all, dropped 82pt below the menu
/// bar. When the content grew instead, the window did not, and the header
/// was cut off.
@MainActor
final class MenuBarPopover {
    let popover = NSPopover()
    let hosting: NSHostingController<AnyView>

    init(engine: ReminderEngine, onOpenSettings: @escaping () -> Void) {
        hosting = NSHostingController(rootView: AnyView(
            MenuBarView(engine: engine)
                .environmentObject(engine)
                .onOpenSettings(onOpenSettings)
        ))
        hosting.sizingOptions = .preferredContentSize
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
    }

    var isShown: Bool { popover.isShown }

    func show(below anchor: NSView) {
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }
}
