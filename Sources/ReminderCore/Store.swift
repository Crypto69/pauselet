import Foundation

/// The on-disk shape of everything the app persists.
public struct AppData: Codable, Equatable, Sendable {
    /// Bumped when the on-disk format changes, so migrations have something to
    /// branch on.
    public var schemaVersion: Int
    public var reminders: [Reminder]
    public var settings: Settings
    public var events: [ReminderEvent]

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = AppData.currentSchemaVersion,
        reminders: [Reminder] = [],
        settings: Settings = Settings(),
        events: [ReminderEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.reminders = reminders
        self.settings = settings
        self.events = events
    }
}

/// Abstracts the filesystem so tests can run against a temp directory.
public protocol DataStoring: AnyObject {
    func load() throws -> AppData
    func save(_ data: AppData) throws
}

/// Persists `AppData` as pretty-printed JSON in a single local file.
///
/// Everything stays on this machine — there is no network path out of this
/// type, by design.
public final class FileDataStore: DataStoring, @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "com.reminder.filedatastore")

    /// The default location: `~/Library/Application Support/Reminder/data.json`.
    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Reminder", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("data.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public convenience init(fileManager: FileManager = .default) throws {
        self.init(fileURL: try FileDataStore.defaultFileURL(fileManager: fileManager))
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Numeric timestamps rather than ISO8601: ISO8601 drops fractional
        // seconds, which would round `lastFiredAt` on every save/load cycle and
        // let interval schedules drift.
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public func load() throws -> AppData {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return AppData(reminders: DefaultReminders.starterSet())
            }
            let raw = try Data(contentsOf: fileURL)
            guard !raw.isEmpty else {
                return AppData(reminders: DefaultReminders.starterSet())
            }
            return try Self.makeDecoder().decode(AppData.self, from: raw)
        }
    }

    public func save(_ data: AppData) throws {
        try queue.sync {
            let encoded = try Self.makeEncoder().encode(data)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            // Atomic write: a crash mid-save must not leave a truncated file
            // that loses every reminder the user configured.
            try encoded.write(to: fileURL, options: .atomic)
        }
    }
}

/// An in-memory store for tests and previews.
public final class InMemoryDataStore: DataStoring, @unchecked Sendable {
    public private(set) var data: AppData
    public private(set) var saveCount = 0

    public init(data: AppData = AppData()) {
        self.data = data
    }

    public func load() throws -> AppData { data }

    public func save(_ data: AppData) throws {
        self.data = data
        saveCount += 1
    }
}

/// The reminders a brand-new install starts with.
public enum DefaultReminders {
    /// Pressure relief and movement prompts, plus a couple of general examples
    /// so the concept of priority tiers is visible immediately.
    public static func starterSet(now: Date = Date()) -> [Reminder] {
        [
            Reminder(
                title: "Tilt Back",
                message: "Tilt your chair back for 5 minutes. Stop working and listen to calming music.",
                schedule: .interval(minutes: 60),
                priority: .critical,
                symbolName: "figure.seated.side",
                activityDurationSeconds: 5 * 60,
                createdAt: now
            ),
            Reminder(
                title: "Weight Shift",
                message: "Activate your glutes and redistribute your weight.",
                schedule: .interval(minutes: 20),
                priority: .subtle,
                symbolName: "arrow.up.and.down.circle",
                createdAt: now
            ),
            Reminder(
                title: "Drink Water",
                message: "Have a drink of water.",
                schedule: .interval(minutes: 60),
                priority: .normal,
                symbolName: "drop.fill",
                createdAt: now
            ),
            Reminder(
                title: "Stretch & Range of Motion",
                message: "Run through your physio stretches.",
                schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
                priority: .important,
                symbolName: "figure.flexibility",
                activityDurationSeconds: 10 * 60,
                isEnabledDefault: false,
                createdAt: now
            ),
        ]
    }
}

private extension Reminder {
    /// Convenience for the starter set: some examples ship switched off so the
    /// user opts in rather than being surprised by them.
    init(
        title: String,
        message: String,
        schedule: Schedule,
        priority: Priority,
        symbolName: String,
        activityDurationSeconds: Int? = nil,
        isEnabledDefault: Bool,
        createdAt: Date
    ) {
        self.init(
            title: title,
            message: message,
            schedule: schedule,
            priority: priority,
            isEnabled: isEnabledDefault,
            symbolName: symbolName,
            activityDurationSeconds: activityDurationSeconds,
            createdAt: createdAt
        )
    }
}
