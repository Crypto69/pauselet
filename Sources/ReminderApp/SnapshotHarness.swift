import AppKit
import SwiftUI
import ReminderCore

/// Renders each UI surface to a PNG and exits.
///
/// Menu bar popovers and full-screen overlays are painful to capture from the
/// running app: a transient popover closes the moment focus shifts, and the
/// overlay covers the whole screen. This harness hosts the real views directly
/// so layout can be checked, reviewed in a pull request, and diffed after a
/// change — using the same code paths the app ships.
///
/// Run with: `Reminder --snapshot <output-directory>`
@MainActor
enum SnapshotHarness {
    /// Reads the launch arguments and, if asked, renders and exits.
    /// Returns true when it handled the launch, so the app should not continue.
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot") else { return false }

        let directory = arguments.indices.contains(flagIndex + 1)
            ? URL(fileURLWithPath: arguments[flagIndex + 1])
            : URL(fileURLWithPath: "build/ui")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        render(into: directory)
        return true
    }

    /// A representative set of reminders, so snapshots show every priority tier
    /// and schedule kind rather than an empty app.
    private static func sampleEngine() -> ReminderEngine {
        let now = Date()
        var tilt = Reminder(
            title: "Tilt Back",
            message: "Tilt your chair back for 5 minutes. Stop working and listen to calming music.",
            schedule: .interval(minutes: 60),
            priority: .critical,
            symbolName: "figure.seated.side",
            activityDurationSeconds: 300,
            createdAt: now
        )
        tilt.lastFiredAt = now.addingTimeInterval(-42 * 60)

        var shift = Reminder(
            title: "Weight Shift",
            message: "Activate your glutes and redistribute your weight.",
            schedule: .interval(minutes: 20),
            priority: .subtle,
            symbolName: "arrow.up.and.down.circle",
            createdAt: now
        )
        shift.lastFiredAt = now.addingTimeInterval(-16 * 60)

        var water = Reminder(
            title: "Drink Water",
            schedule: .interval(minutes: 60),
            priority: .normal,
            symbolName: "drop.fill",
            createdAt: now
        )
        water.lastFiredAt = now.addingTimeInterval(-25 * 60)

        var physio = Reminder(
            title: "Stretch & Range of Motion",
            message: "Run through your physio stretches.",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            priority: .important,
            symbolName: "figure.flexibility",
            activityDurationSeconds: 600,
            createdAt: now
        )
        physio.isEnabled = false

        let call = Reminder(
            title: "Call Mum",
            schedule: .weeklyAt(hour: 18, minute: 30, weekdays: [1, 4]),
            priority: .normal,
            symbolName: "phone.fill",
            createdAt: now
        )

        let store = InMemoryDataStore(
            data: AppData(reminders: [tilt, shift, water, physio, call])
        )
        return ReminderEngine(store: store)
    }

    private static func render(into directory: URL) {
        let engine = sampleEngine()

        snapshot(
            MenuBarView(engine: engine).environmentObject(engine),
            size: NSSize(width: 380, height: 470),
            named: "popover",
            into: directory
        )

        snapshot(
            SettingsView().environmentObject(engine),
            size: NSSize(width: 760, height: 560),
            named: "settings",
            into: directory
        )

        if let tilt = engine.reminders.first(where: { $0.priority == .critical }) {
            snapshot(
                CriticalOverlayView(reminder: tilt, onComplete: {}, onSnooze: {}),
                size: NSSize(width: 1280, height: 800),
                named: "overlay-critical",
                into: directory
            )
        }

        if let shift = engine.reminders.first(where: { $0.priority == .subtle }) {
            snapshot(
                SubtleHintView(reminder: shift, onComplete: {})
                    .padding(20)
                    .background(Color.gray.opacity(0.25)),
                size: NSSize(width: 360, height: 132),
                named: "overlay-subtle",
                into: directory
            )
        }

        snapshot(
            ReminderEditor(reminder: engine.reminders.first) { _ in },
            size: NSSize(width: 460, height: 620),
            named: "editor",
            into: directory
        )
    }

    private static func snapshot<V: View>(
        _ view: V,
        size: NSSize,
        named name: String,
        into directory: URL
    ) {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hosting.frame = NSRect(origin: .zero, size: size)

        // Hosting the view in a real window lets materials, vibrancy and the
        // system appearance resolve the way they do in the app.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.backgroundColor = .clear
        window.orderFrontRegardless()

        // Give SwiftUI a turn of the run loop to lay out before snapshotting;
        // without this, the first frame can come out blank.
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("snapshot \(name): could not allocate bitmap")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("snapshot \(name): could not encode PNG")
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            print("snapshot \(name): \(url.path)")
        } catch {
            print("snapshot \(name): write failed — \(error)")
        }
        window.orderOut(nil)
    }
}
