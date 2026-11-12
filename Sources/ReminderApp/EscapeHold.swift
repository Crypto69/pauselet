import Foundation
import ReminderCore

/// The emergency exit from a locked takeover: Escape held for a few seconds.
///
/// Key events arrive as `began()` and `ended()`; the hold is measured from
/// the wall clock on a short timer so a progress bar can fill, and
/// `onComplete` fires once when the full time has been held. Letting go
/// early resets it. Kept apart from `NSEvent` so a test can drive it.
@MainActor
final class EscapeHold: ObservableObject {
    /// 0 while not holding, 1 the moment the exit fires.
    @Published private(set) var progress: Double = 0
    let holdSeconds: TimeInterval
    var onComplete: (() -> Void)?
    private var startedAt: Date?
    private var timer: Timer?

    init(holdSeconds: TimeInterval = Scheduler.emergencyExitHoldSeconds) {
        self.holdSeconds = max(0.05, holdSeconds)
    }

    var isHolding: Bool { startedAt != nil }

    /// A key-down. Key repeat sends many; only the first starts the clock.
    func began() {
        guard startedAt == nil else { return }
        startedAt = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A key-up, or the takeover going away: back to nothing.
    func ended() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        progress = 0
    }

    private func tick() {
        guard let startedAt else { return }
        progress = min(1, Date().timeIntervalSince(startedAt) / holdSeconds)
        if progress >= 1 {
            let complete = onComplete
            ended()
            complete?()
        }
    }
}
