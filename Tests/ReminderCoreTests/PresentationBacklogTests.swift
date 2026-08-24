import XCTest
@testable import ReminderCore

/// Tests for what happens to reminders that queued up behind a critical
/// overlay nobody acknowledged.
///
/// The scenario: "Tilt Back" takes over the screen and the user falls asleep
/// in front of it, or leaves the desk for the afternoon. The engine keeps
/// ticking, so every reminder that falls due in those hours fires into the
/// presenter and queues behind the occupied screen. Pressing Finish hours
/// later must not replay that backlog as a chain of consecutive takeovers —
/// only what is genuinely current still deserves the screen.
@MainActor
final class PresentationBacklogTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeReminder(title: String) -> Reminder {
        Reminder(
            title: title,
            schedule: .interval(minutes: 30),
            priority: .critical,
            createdAt: now
        )
    }

    // MARK: - The pruning policy

    /// A reminder that queued moments before the acknowledgment is genuinely
    /// current — after sleep several criticals routinely fire on the same
    /// tick, and the second must still be shown once the first is dealt with.
    func testFreshlyQueuedReminderIsStillShown() {
        let queued = makeReminder(title: "Stretch")
        let acknowledged = makeReminder(title: "Tilt Back")

        XCTAssertTrue(
            ReminderEngine.shouldPresentQueued(
                reminderID: queued.id,
                queuedAt: now.addingTimeInterval(-30),
                acknowledgedID: acknowledged.id,
                now: now
            )
        )
    }

    /// The complaint this policy exists for: an entry that waited hours behind
    /// an unacknowledged overlay has had its moment pass, and must not be
    /// delivered as the "next" takeover.
    func testStaleQueuedReminderIsDropped() {
        let queued = makeReminder(title: "Stretch")
        let acknowledged = makeReminder(title: "Tilt Back")

        XCTAssertFalse(
            ReminderEngine.shouldPresentQueued(
                reminderID: queued.id,
                queuedAt: now.addingTimeInterval(-3 * 3600),
                acknowledgedID: acknowledged.id,
                now: now
            )
        )
    }

    /// The boundary matches `absorbBacklogFromDowntime`: exactly at the grace
    /// cutoff counts as stale, strictly inside it counts as current.
    func testGraceBoundary() {
        let queued = makeReminder(title: "Stretch")
        let acknowledged = makeReminder(title: "Tilt Back")
        let cutoff = now.addingTimeInterval(-ReminderEngine.downtimeGrace)

        XCTAssertFalse(
            ReminderEngine.shouldPresentQueued(
                reminderID: queued.id, queuedAt: cutoff,
                acknowledgedID: acknowledged.id, now: now
            ),
            "An entry exactly at the cutoff is stale"
        )
        XCTAssertTrue(
            ReminderEngine.shouldPresentQueued(
                reminderID: queued.id, queuedAt: cutoff.addingTimeInterval(1),
                acknowledgedID: acknowledged.id, now: now
            ),
            "An entry just inside the grace window is current"
        )
    }

    /// While the overlay sat unacknowledged, the same interval reminder kept
    /// falling due and queueing copies of itself. Saying "done" answers all of
    /// them — even a copy queued seconds ago must not reappear over an
    /// acknowledgment the user just gave.
    func testQueuedDuplicateOfTheAcknowledgedReminderIsDroppedHoweverFresh() {
        let tilt = makeReminder(title: "Tilt Back")

        XCTAssertFalse(
            ReminderEngine.shouldPresentQueued(
                reminderID: tilt.id,
                queuedAt: now.addingTimeInterval(-10),
                acknowledgedID: tilt.id,
                now: now
            )
        )
    }

    /// The full night-asleep shape: hours of re-fires of the on-screen
    /// reminder, a stale different reminder from mid-afternoon, and one other
    /// reminder that fired just before the user woke up. Finish must surface
    /// only the last of these.
    func testHoursOfBacklogCollapseToTheOneCurrentReminder() {
        let tilt = makeReminder(title: "Tilt Back")
        let stretch = makeReminder(title: "Stretch")
        let meds = makeReminder(title: "Evening Meds")

        // (reminder, how long ago it queued)
        let queue: [(reminder: Reminder, age: TimeInterval)] = [
            (tilt, 3 * 3600),
            (stretch, 2 * 3600),
            (tilt, 3600),
            (tilt, 40),  // fresh, but the user just answered this reminder
            (meds, 60),  // fresh and unanswered: still deserves the screen
        ]

        let surviving = queue.filter {
            ReminderEngine.shouldPresentQueued(
                reminderID: $0.reminder.id,
                queuedAt: now.addingTimeInterval(-$0.age),
                acknowledgedID: tilt.id,
                now: now
            )
        }

        XCTAssertEqual(surviving.map(\.reminder.id), [meds.id])
    }

    // MARK: - History

    /// A dropped entry is recorded as missed, so the history tab still shows
    /// what became of the fires that queued while nobody was watching.
    func testDroppedPresentationsAreRecordedAsMissedAndPersisted() {
        let tilt = makeReminder(title: "Tilt Back")
        let stretch = makeReminder(title: "Stretch")
        let store = InMemoryDataStore(
            data: AppData(reminders: [tilt, stretch])
        )
        let clock = MutableDateProvider(now: now)
        let engine = ReminderEngine(store: store, dateProvider: clock)
        let savesBefore = store.saveCount

        engine.recordMissedPresentations([tilt, stretch])

        XCTAssertEqual(
            engine.events.map(\.outcome), [.missed, .missed]
        )
        XCTAssertEqual(
            engine.events.map(\.reminderID), [tilt.id, stretch.id]
        )
        XCTAssertGreaterThan(
            store.saveCount, savesBefore,
            "Missed events must survive a relaunch"
        )
    }

    /// The common case — the queue was empty, or everything in it was still
    /// current — must not write to disk or touch history at all.
    func testRecordingNothingIsANoOp() {
        let store = InMemoryDataStore(data: AppData(reminders: []))
        let clock = MutableDateProvider(now: now)
        let engine = ReminderEngine(store: store, dateProvider: clock)
        let savesBefore = store.saveCount

        engine.recordMissedPresentations([])

        XCTAssertTrue(engine.events.isEmpty)
        XCTAssertEqual(store.saveCount, savesBefore)
    }
}
