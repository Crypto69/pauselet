import AppKit
import Foundation

/// The activity countdown for one critical takeover — "tilt back for five
/// minutes" — shared by every display's copy of the overlay, so there is one
/// clock and one chime however many screens show it. Derived from the wall
/// clock rather than counted per tick, so a Mac that idles mid-activity still
/// finishes on time.
@MainActor
final class ActivityCountdown: ObservableObject {
    @Published private(set) var remaining: Int
    @Published private(set) var hasStarted = false

    let total: Int
    private let playsChime: Bool
    private var deadline: Date?
    private var timer: Timer?

    /// - Parameter playsChime: Whether reaching zero plays the finishing
    ///   sound; off for snapshots and previews.
    init(seconds: Int, playsChime: Bool) {
        total = max(0, seconds)
        remaining = total
        self.playsChime = playsChime
    }

    /// False for a reminder with no activity duration: nothing to show.
    var isAvailable: Bool { total > 0 }

    /// 0 at the start, 1 when the time is up; what the ring draws.
    var progress: Double {
        total > 0 ? 1 - (Double(remaining) / Double(total)) : 0
    }

    /// Starts the clock the first time the overlay appears; later appearances
    /// (another display's copy) join the countdown already running.
    func start() {
        guard isAvailable, !hasStarted else { return }
        hasStarted = true
        deadline = Date().addingTimeInterval(TimeInterval(total))
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Keep counting while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let deadline, remaining > 0 else { return }
        remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        if remaining == 0 {
            // The activity is finished; let the user see that before it closes.
            if playsChime { Sounds.play(named: "Glass") }
            stop()
        }
    }
}
