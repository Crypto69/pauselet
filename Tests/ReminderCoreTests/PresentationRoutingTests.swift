import XCTest
@testable import ReminderCore

/// A presenter that records how each reminder would be shown, standing in for
/// the app's real routing (subtle card / notification / full-screen overlay).
///
/// The app layer cannot be imported here, so this mirrors the same decision the
/// `OverlayPresenter` makes. The point is to pin down the routing rules, which
/// are the part a user actually feels.
final class RoutingPresenter: ReminderPresenting {
    enum Surface: Equatable {
        case subtleCard
        case notification
        case fullScreenOverlay
    }

    private(set) var routed: [(title: String, surface: Surface)] = []
    private(set) var dismissAllCount = 0

    /// Mirrors `OverlayPresenter.present`.
    static func surface(for priority: Priority) -> Surface {
        switch priority {
        case .subtle: return .subtleCard
        case .normal, .important: return .notification
        case .critical: return .fullScreenOverlay
        }
    }

    func present(_ reminder: Reminder, settings: Settings) {
        routed.append((reminder.title, Self.surface(for: reminder.priority)))
    }

    func dismissAll() { dismissAllCount += 1 }
}

@MainActor
final class PresentationRoutingTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func makeDueReminder(
        title: String, priority: Priority, at start: Date
    ) -> Reminder {
        var reminder = Reminder(
            title: title, schedule: .interval(minutes: 10),
            priority: priority, createdAt: start
        )
        reminder.lastFiredAt = start
        return reminder
    }

    /// Each tier must reach a genuinely different surface. This is the whole
    /// premise of the app: a 20-minute nudge and an hourly pressure-relief
    /// prompt must not feel the same.
    func testEachPriorityRoutesToItsOwnSurface() {
        XCTAssertEqual(RoutingPresenter.surface(for: .subtle), .subtleCard)
        XCTAssertEqual(RoutingPresenter.surface(for: .normal), .notification)
        XCTAssertEqual(RoutingPresenter.surface(for: .important), .notification)
        XCTAssertEqual(RoutingPresenter.surface(for: .critical), .fullScreenOverlay)
    }

    func testFiredRemindersAreRoutedByPriority() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reminders = [
            makeDueReminder(title: "Shift", priority: .subtle, at: start),
            makeDueReminder(title: "Water", priority: .normal, at: start),
            makeDueReminder(title: "Meds", priority: .important, at: start),
            makeDueReminder(title: "Tilt", priority: .critical, at: start),
        ]
        let store = InMemoryDataStore(data: AppData(reminders: reminders))
        let clock = MutableDateProvider(now: start)
        let presenter = RoutingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: calendar
        )

        clock.advance(by: 10 * 60)
        engine.tick()

        XCTAssertEqual(
            presenter.routed.map(\.surface),
            [.subtleCard, .notification, .notification, .fullScreenOverlay],
            "Presented lowest priority first, so the overlay lands on top"
        )
    }

    /// The default reminders must map to the presentations they were designed
    /// for: the hourly tilt takes over the screen, the 20-minute shift does not.
    func testStarterSetRoutesTheWayItWasDesignedTo() {
        let starters = DefaultReminders.starterSet()

        let tilt = starters.first { $0.title == "Tilt Back" }!
        XCTAssertEqual(
            RoutingPresenter.surface(for: tilt.priority), .fullScreenOverlay,
            "The hourly pressure-relief prompt must interrupt"
        )

        let shift = starters.first { $0.title == "Weight Shift" }!
        XCTAssertEqual(
            RoutingPresenter.surface(for: shift.priority), .subtleCard,
            "A nudge every 20 minutes must stay quiet or it gets tuned out"
        )

        let water = starters.first { $0.title == "Drink Water" }!
        XCTAssertEqual(RoutingPresenter.surface(for: water.priority), .notification)
    }

    /// Pausing must clear anything already on screen, not just stop new ones.
    func testPausingClearsWhateverIsOnScreen() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = makeDueReminder(title: "Tilt", priority: .critical, at: start)
        let store = InMemoryDataStore(data: AppData(reminders: [reminder]))
        let clock = MutableDateProvider(now: start)
        let presenter = RoutingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: calendar
        )

        clock.advance(by: 10 * 60)
        engine.tick()
        XCTAssertEqual(presenter.routed.count, 1)

        engine.setPaused(true)
        XCTAssertEqual(presenter.dismissAllCount, 1)
    }

    /// A reminder with an activity duration drives the countdown, so the value
    /// has to survive into what gets presented.
    func testActivityDurationReachesThePresenter() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var reminder = makeDueReminder(title: "Tilt", priority: .critical, at: start)
        reminder.activityDurationSeconds = 5 * 60

        let store = InMemoryDataStore(data: AppData(reminders: [reminder]))
        let clock = MutableDateProvider(now: start)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: calendar
        )

        clock.advance(by: 10 * 60)
        engine.tick()

        XCTAssertEqual(presenter.presented.first?.activityDurationSeconds, 300)
    }
}
