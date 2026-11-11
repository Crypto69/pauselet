import AppKit
import SwiftUI
import XCTest

/// Hosts a SwiftUI view in a real window so its AppKit-backed controls lay
/// out the way they do in the app, and lets a test find and measure them.
///
/// By default the window is never shown: layout, frames and focus all work
/// without the window server drawing anything. `capture()` needs the window
/// on screen; it is placed beneath the desktop picture, so the compositor
/// draws it but nobody sees it (the window's own backing store is what gets
/// captured, regardless of what covers it).
@MainActor
final class RenderedView {
    let hosting: NSView
    let window: NSWindow

    init<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name = .darkAqua) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        self.hosting = hosting
        self.window = window
        settle()
    }

    deinit {
        let window = window
        MainActor.assumeIsolated { window.orderOut(nil) }
    }

    /// Turns the run loop so SwiftUI lays out, resolves text and draws.
    func settle(turns: Int = 6) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
            hosting.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    /// Every view of type `T`, in tree order (top to bottom for a form).
    func views<T: NSView>(of type: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return found.sorted { frame(of: $0).minY < frame(of: $1).minY }
    }

    /// A view's frame in the hosting view's coordinates, top-left origin.
    func frame(of view: NSView) -> CGRect {
        let inWindow = view.convert(view.bounds, to: nil)
        return CGRect(
            x: inWindow.minX, y: hosting.bounds.height - inWindow.maxY,
            width: inWindow.width, height: inWindow.height
        )
    }

    // MARK: - Pixels

    /// The window as the compositor drew it, at the display's backing scale.
    func capture() throws -> Bitmap {
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        window.orderFrontRegardless()
        settle(turns: 8)
        defer { window.orderOut(nil) }
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw XCTSkip("Could not capture the window (no window server?)")
        }
        return Bitmap(image, pointWidth: hosting.bounds.width)
    }
}

/// Pixel access and ink measurement for a captured window.
struct Bitmap {
    let rep: NSBitmapImageRep
    /// Device pixels per point.
    let scale: CGFloat

    init(_ image: CGImage, pointWidth: CGFloat) {
        rep = NSBitmapImageRep(cgImage: image)
        scale = CGFloat(image.width) / pointWidth
    }

    private func luminance(_ x: Int, _ y: Int) -> CGFloat {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return (c.redComponent + c.greenComponent + c.blueComponent) / 3
    }

    /// The vertical extent, in points from the top, of the ink — pixels that
    /// differ clearly from the background — inside `rect` (points).
    ///
    /// Rows where ink spans most of the width are a control's border or a
    /// separator rather than glyphs, so they are left out.
    func inkExtent(in rect: CGRect, threshold: CGFloat = 0.25) -> ClosedRange<CGFloat>? {
        let x0 = Int((rect.minX * scale).rounded()), x1 = Int((rect.maxX * scale).rounded())
        let y0 = Int((rect.minY * scale).rounded()), y1 = Int((rect.maxY * scale).rounded())
        guard x1 > x0, y1 > y0 else { return nil }
        let background = self.background(x0..<x1, y0..<y1)
        var rows: [Int] = []
        for y in max(0, y0)..<min(rep.pixelsHigh, y1) {
            var ink = 0
            for x in max(0, x0)..<min(rep.pixelsWide, x1)
            where abs(luminance(x, y) - background) > threshold {
                ink += 1
            }
            if ink > 0, Double(ink) < Double(x1 - x0) * 0.6 { rows.append(y) }
        }
        guard let top = rows.min(), let bottom = rows.max() else { return nil }
        return CGFloat(top) / scale...CGFloat(bottom + 1) / scale
    }

    /// Rows (points from the top) where nearly the whole width of `rect`
    /// differs from the background, however faintly: separators and borders.
    func lineRows(in rect: CGRect, threshold: CGFloat = 0.03) -> [CGFloat] {
        let x0 = Int((rect.minX * scale).rounded()), x1 = Int((rect.maxX * scale).rounded())
        let y0 = Int((rect.minY * scale).rounded()), y1 = Int((rect.maxY * scale).rounded())
        let background = self.background(x0..<x1, y0..<y1)
        return (max(0, y0)..<min(rep.pixelsHigh, y1)).filter { y in
            let ink = (max(0, x0)..<min(rep.pixelsWide, x1)).filter {
                abs(luminance($0, y) - background) > threshold
            }.count
            return Double(ink) >= Double(x1 - x0) * 0.9
        }.map { CGFloat($0) / scale }
    }

    /// The commonest luminance in a region: its background.
    private func background(_ xs: Range<Int>, _ ys: Range<Int>) -> CGFloat {
        var counts: [Int: Int] = [:]
        for y in ys.clamped(to: 0..<rep.pixelsHigh) where y % 2 == 0 {
            for x in xs.clamped(to: 0..<rep.pixelsWide) where x % 2 == 0 {
                counts[Int(luminance(x, y) * 100), default: 0] += 1
            }
        }
        return CGFloat(counts.max { $0.value < $1.value }?.key ?? 0) / 100
    }

    func save(to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Whether to run tests that need the window server to composite a window.
/// They never put anything in front of the user, but they do need a logged-in
/// GUI session, so they stay opt-in: `PAUSELET_VISUAL_TESTS=1 swift test`.
func requireVisualTests() throws {
    guard ProcessInfo.processInfo.environment["PAUSELET_VISUAL_TESTS"] == "1" else {
        throw XCTSkip("Set PAUSELET_VISUAL_TESTS=1 to run pixel and popover tests")
    }
}
