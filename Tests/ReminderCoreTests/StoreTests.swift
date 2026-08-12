import XCTest
@testable import ReminderCore

/// Tests that data survives a round trip to disk and that a damaged file cannot
/// take the app down on launch.
final class StoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReminderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
    }

    private func makeStore() -> FileDataStore {
        FileDataStore(fileURL: tempDirectory.appendingPathComponent("data.json"))
    }

    // MARK: - Round trip

    func testSaveThenLoadPreservesEverything() throws {
        let store = makeStore()
        let reminder = Reminder(
            title: "Tilt Back",
            message: "Tilt for 5 minutes.",
            schedule: .interval(minutes: 60),
            priority: .critical,
            symbolName: "figure.seated.side",
            activityDurationSeconds: 300,
            lastFiredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var settings = Settings()
        settings.snoozeMinutes = 12
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 21, startMinute: 30,
            endHour: 6, endMinute: 45, allowsCritical: true
        )
        let event = ReminderEvent(
            reminderID: reminder.id, reminderTitle: reminder.title,
            date: Date(timeIntervalSince1970: 1_700_000_100), outcome: .completed
        )
        let data = AppData(reminders: [reminder], settings: settings, events: [event])

        try store.save(data)
        let loaded = try store.load()

        // Exact equality: dates are stored at whole-second precision precisely
        // so a reloaded value compares equal to the one written.
        XCTAssertEqual(loaded, FileDataStore.normalizingDates(data))
    }

    func testEachScheduleKindSurvivesRoundTrip() throws {
        let store = makeStore()
        let schedules: [Schedule] = [
            .interval(minutes: 20),
            .dailyAt(hour: 17, minute: 30, dayInterval: 2),
            .weeklyAt(hour: 8, minute: 0, weekdays: [2, 4, 6]),
        ]
        let reminders = schedules.enumerated().map { index, schedule in
            Reminder(title: "R\(index)", schedule: schedule)
        }

        try store.save(AppData(reminders: reminders))
        let loaded = try store.load()

        XCTAssertEqual(loaded.reminders.map(\.schedule), schedules)
    }

    // MARK: - First launch

    func testMissingFileYieldsStarterSet() throws {
        let store = makeStore()
        let loaded = try store.load()

        XCTAssertFalse(loaded.reminders.isEmpty)
        XCTAssertTrue(
            loaded.reminders.contains { $0.title == "Tilt Back" },
            "The hourly pressure-relief reminder should ship by default"
        )
        XCTAssertTrue(loaded.reminders.contains { $0.title == "Weight Shift" })
    }

    func testStarterSetUsesTheRequestedSchedulesAndPriorities() {
        let reminders = DefaultReminders.starterSet()

        let tilt = reminders.first { $0.title == "Tilt Back" }
        XCTAssertEqual(tilt?.schedule, .interval(minutes: 60))
        XCTAssertEqual(tilt?.priority, .critical, "Hourly tilt must be intrusive")
        XCTAssertEqual(tilt?.activityDurationSeconds, 300, "Five-minute tilt countdown")
        XCTAssertTrue(tilt?.isEnabled ?? false)

        let shift = reminders.first { $0.title == "Weight Shift" }
        XCTAssertEqual(shift?.schedule, .interval(minutes: 20))
        XCTAssertEqual(shift?.priority, .subtle, "Twenty-minute nudge must be subtle")
        XCTAssertTrue(shift?.isEnabled ?? false)

        // Optional examples ship switched off so nothing surprises a new user.
        let physio = reminders.first { $0.title == "Stretch & Range of Motion" }
        XCTAssertEqual(physio?.schedule, .dailyAt(hour: 17, minute: 0, dayInterval: 2))
        XCTAssertFalse(physio?.isEnabled ?? true)
    }

    func testEmptyFileYieldsStarterSetRatherThanThrowing() throws {
        let url = tempDirectory.appendingPathComponent("data.json")
        try Data().write(to: url)
        let store = FileDataStore(fileURL: url)

        let loaded = try store.load()
        XCTAssertFalse(loaded.reminders.isEmpty)
    }

    /// A first launch must write the starter set to disk immediately. Without
    /// this the file stays absent until the user changes something, so every
    /// relaunch reseeds `createdAt` and the interval anchors slide forward.
    @MainActor
    func testFirstLaunchPersistsStarterSetSoAnchorsSurviveRelaunch() throws {
        let store = makeStore()
        XCTAssertFalse(store.hasPersistedData)

        let first = ReminderEngine(store: store)
        XCTAssertTrue(
            store.hasPersistedData,
            "Starting with no data file should write one"
        )
        let originalAnchors = first.reminders
            .map { $0.createdAt.timeIntervalSince1970 }
            .sorted()

        // A second launch against the same file must reuse the stored anchors.
        let second = ReminderEngine(store: FileDataStore(fileURL: store.fileURL))
        let reloadedAnchors = second.reminders
            .map { $0.createdAt.timeIntervalSince1970 }
            .sorted()

        XCTAssertEqual(originalAnchors.count, reloadedAnchors.count)
        for (original, reloaded) in zip(originalAnchors, reloadedAnchors) {
            XCTAssertEqual(original, reloaded, accuracy: 0.001)
        }
    }

    // MARK: - Corruption

    func testCorruptFileThrowsSoTheEngineCanFallBack() throws {
        let url = tempDirectory.appendingPathComponent("data.json")
        try Data("{ this is not json".utf8).write(to: url)
        let store = FileDataStore(fileURL: url)

        XCTAssertThrowsError(try store.load())
    }

    /// An unreadable file must be preserved before the fallback path can
    /// overwrite it, so the user's data survives a decode bug.
    func testCorruptFileIsBackedUpBeforeFallback() throws {
        let url = tempDirectory.appendingPathComponent("data.json")
        let corruptBytes = Data("{ this is not json".utf8)
        try corruptBytes.write(to: url)
        let store = FileDataStore(fileURL: url)

        XCTAssertThrowsError(try store.load())

        let backup = try Data(contentsOf: store.corruptBackupURL)
        XCTAssertEqual(backup, corruptBytes, "The original bytes are kept intact")

        // The fallback overwrite must not touch the backup.
        try store.save(AppData(reminders: DefaultReminders.starterSet()))
        XCTAssertEqual(try Data(contentsOf: store.corruptBackupURL), corruptBytes)
    }

    /// The engine must start with defaults rather than crashing when the file
    /// on disk is unreadable.
    @MainActor
    func testEngineRecoversFromCorruptFile() throws {
        let url = tempDirectory.appendingPathComponent("data.json")
        try Data("not json at all".utf8).write(to: url)
        let store = FileDataStore(fileURL: url)

        let engine = ReminderEngine(store: store)
        XCTAssertFalse(engine.reminders.isEmpty, "Falls back to the starter set")
    }

    // MARK: - Writes

    func testSaveOverwritesPreviousContents() throws {
        let store = makeStore()
        try store.save(AppData(reminders: [Reminder(title: "First", schedule: .interval(minutes: 10))]))
        try store.save(AppData(reminders: [Reminder(title: "Second", schedule: .interval(minutes: 10))]))

        let loaded = try store.load()
        XCTAssertEqual(loaded.reminders.map(\.title), ["Second"])
    }

    func testSaveCreatesMissingDirectory() throws {
        let nested = tempDirectory
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("data.json")
        let store = FileDataStore(fileURL: nested)

        try store.save(AppData(reminders: [Reminder(title: "Deep", schedule: .interval(minutes: 5))]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testSchemaVersionIsRecorded() throws {
        let store = makeStore()
        try store.save(AppData())
        let loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, AppData.currentSchemaVersion)
    }

    /// Data is written as plain local JSON — no network, no cloud.
    func testDataIsStoredAsReadableLocalJSON() throws {
        let store = makeStore()
        try store.save(
            AppData(reminders: [Reminder(title: "Local Only", schedule: .interval(minutes: 30))])
        )

        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("Local Only"))
        XCTAssertTrue(raw.contains("schemaVersion"))
    }

    func testDefaultFileURLIsInsideApplicationSupport() throws {
        let url = try FileDataStore.defaultFileURL()
        XCTAssertEqual(url.lastPathComponent, "data.json")
        XCTAssertTrue(url.path.contains("Application Support/Pauselet"))
    }

    /// The rename must not orphan an existing install: data written under the
    /// app's old name is adopted, rather than the app finding an empty folder
    /// and reseeding the starter set over the top of the user's reminders.
    func testDataFromTheOldAppNameIsAdopted() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = base.appendingPathComponent("Reminder", isDirectory: true)
        let current = base.appendingPathComponent("Pauselet", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let original = AppData(reminders: [
            Reminder(title: "Tilt Back", schedule: .interval(minutes: 60)),
        ])
        try FileDataStore(
            fileURL: legacy.appendingPathComponent("data.json")
        ).save(original)

        FileDataStore.migrateLegacyDirectoryIfNeeded(
            into: current, base: base, fileManager: .default
        )

        let migrated = try FileDataStore(
            fileURL: current.appendingPathComponent("data.json")
        ).load()
        XCTAssertEqual(migrated.reminders.map(\.title), ["Tilt Back"])
        // The old copy stays put as a safety net.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent("data.json").path
            )
        )
    }

    /// Migration must never overwrite newer data with older. Once the current
    /// folder has its own file, the old one is ignored for good.
    func testExistingDataIsNeverOverwrittenByTheOldCopy() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = base.appendingPathComponent("Reminder", isDirectory: true)
        let current = base.appendingPathComponent("Pauselet", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileDataStore(fileURL: legacy.appendingPathComponent("data.json"))
            .save(AppData(reminders: [
                Reminder(title: "Stale", schedule: .interval(minutes: 60)),
            ]))
        try FileDataStore(fileURL: current.appendingPathComponent("data.json"))
            .save(AppData(reminders: [
                Reminder(title: "Current", schedule: .interval(minutes: 60)),
            ]))

        FileDataStore.migrateLegacyDirectoryIfNeeded(
            into: current, base: base, fileManager: .default
        )

        let loaded = try FileDataStore(
            fileURL: current.appendingPathComponent("data.json")
        ).load()
        XCTAssertEqual(loaded.reminders.map(\.title), ["Current"])
    }
}
