import Foundation

/// How intrusive a reminder should be when it fires.
///
/// The tiers exist so a user can distinguish "you must stop what you are doing
/// right now" from "a gentle nudge you may ignore". This is the core of the
/// app's accessibility story: pressure-relief reminders are medically important
/// and need to interrupt, while a water reminder should not.
public enum Priority: String, Codable, CaseIterable, Sendable, Comparable {
    /// A quiet, self-dismissing hint. No sound. Used for frequent micro-nudges.
    case subtle
    /// A standard notification that stays in Notification Center.
    case normal
    /// A notification with sound that persists until acknowledged.
    case important
    /// A full-screen overlay that takes over every display until acknowledged.
    case critical

    public var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .important: return "Important"
        case .critical: return "Critical"
        }
    }

    public var explanation: String {
        switch self {
        case .subtle: return "Brief silent hint near the menu bar"
        case .normal: return "Standard notification"
        case .important: return "Notification with sound, stays until dismissed"
        case .critical: return "Full-screen overlay on every display"
        }
    }

    /// SF Symbol used to represent the tier in the UI.
    public var symbolName: String {
        switch self {
        case .subtle: return "circle.dotted"
        case .normal: return "bell"
        case .important: return "bell.badge"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    private var rank: Int {
        switch self {
        case .subtle: return 0
        case .normal: return 1
        case .important: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Describes when a reminder recurs.
public enum Schedule: Codable, Equatable, Sendable {
    /// Fires every `minutes` minutes, measured from the last time it fired.
    case interval(minutes: Int)

    /// Fires at a fixed wall-clock time, every `dayInterval` days.
    /// `dayInterval == 1` means daily; `2` means every second day.
    case dailyAt(hour: Int, minute: Int, dayInterval: Int)

    /// Fires at a fixed wall-clock time on specific weekdays.
    /// Weekdays use `Calendar` numbering: 1 = Sunday ... 7 = Saturday.
    case weeklyAt(hour: Int, minute: Int, weekdays: Set<Int>)

    public var summary: String {
        switch self {
        case .interval(let minutes):
            return "Every \(Self.humanDuration(minutes: minutes))"
        case .dailyAt(let hour, let minute, let dayInterval):
            let time = Self.humanTime(hour: hour, minute: minute)
            if dayInterval <= 1 { return "Daily at \(time)" }
            return "Every \(dayInterval) days at \(time)"
        case .weeklyAt(let hour, let minute, let weekdays):
            let time = Self.humanTime(hour: hour, minute: minute)
            let names = weekdays.sorted().map { Self.weekdayName($0) }.joined(separator: ", ")
            return "\(names) at \(time)"
        }
    }

    /// Whether this schedule fires at fixed wall-clock moments (daily/weekly)
    /// rather than a rolling interval. Wall-clock slots that pass unheard
    /// inside quiet hours are skipped; interval reminders are delivered once
    /// the window ends.
    public var isWallClock: Bool {
        if case .interval = self { return false }
        return true
    }

    public static func humanDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "hour" : "\(hours) hours"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func humanTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func weekdayName(_ weekday: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let index = weekday - 1
        guard names.indices.contains(index) else { return "?" }
        return names[index]
    }
}

/// A single user-defined recurring reminder.
public struct Reminder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// Longer text shown in the notification body / overlay.
    public var message: String
    public var schedule: Schedule
    public var priority: Priority
    public var isEnabled: Bool
    /// SF Symbol shown alongside the reminder.
    public var symbolName: String
    /// For reminders describing a timed activity (e.g. "tilt back for 5 minutes"),
    /// the overlay shows a countdown of this length. `nil` means no countdown.
    public var activityDurationSeconds: Int?
    /// Optional sound played when the reminder fires. `nil` uses the tier default.
    public var soundName: String?
    /// How long a subtle card stays on screen, in seconds. `nil` uses the global
    /// setting.
    ///
    /// Only applies to the subtle tier: Normal and Important are macOS
    /// notifications, whose on-screen time the system controls, and Critical
    /// stays until acknowledged.
    public var displaySeconds: Int?
    /// What music this reminder starts when it fires.
    ///
    /// Decoded leniently: reminders written before this existed have no `music`
    /// key at all, and must load as "no music" rather than failing the whole
    /// file and losing every reminder the user configured.
    public var music: MusicChoice
    /// The exercise list for an "Exercise" reminder; `nil` for an ordinary
    /// reminder.
    ///
    /// Decoded leniently for the same reason as `music`: files written before
    /// this existed have no `exercises` key. Never stored empty — the editor
    /// collapses an empty list to `nil` through `Exercise.normalized` — but an
    /// empty array read from disk is kept as-is so the file re-encodes
    /// byte-identically.
    public var exercises: [Exercise]?
    /// When the reminder last fired. Drives interval scheduling.
    public var lastFiredAt: Date?
    /// When the reminder was last acknowledged (completed or dismissed).
    public var lastAcknowledgedAt: Date?
    /// When set, the reminder is snoozed and must not fire before this date.
    public var snoozedUntil: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        message: String = "",
        schedule: Schedule,
        priority: Priority = .normal,
        isEnabled: Bool = true,
        symbolName: String = "bell",
        activityDurationSeconds: Int? = nil,
        soundName: String? = nil,
        displaySeconds: Int? = nil,
        music: MusicChoice = .none,
        exercises: [Exercise]? = nil,
        lastFiredAt: Date? = nil,
        lastAcknowledgedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.schedule = schedule
        self.priority = priority
        self.isEnabled = isEnabled
        self.symbolName = symbolName
        self.activityDurationSeconds = activityDurationSeconds
        self.soundName = soundName
        self.displaySeconds = displaySeconds
        self.music = music
        self.exercises = exercises
        self.lastFiredAt = lastFiredAt
        self.lastAcknowledgedAt = lastAcknowledgedAt
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
    }

    /// Decodes `music` and `exercises` as optional so a data file written
    /// before those features existed still loads. Every other field keeps the
    /// synthesized behaviour.
    ///
    /// Without this, adding the field would make `JSONDecoder` throw on an
    /// existing install, which `ReminderEngine.loadFromStore` handles by
    /// falling back to the starter set — quietly wiping the user's reminders.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        message = try container.decode(String.self, forKey: .message)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        priority = try container.decode(Priority.self, forKey: .priority)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        activityDurationSeconds = try container.decodeIfPresent(
            Int.self, forKey: .activityDurationSeconds
        )
        soundName = try container.decodeIfPresent(String.self, forKey: .soundName)
        displaySeconds = try container.decodeIfPresent(Int.self, forKey: .displaySeconds)
        music = try container.decodeIfPresent(MusicChoice.self, forKey: .music) ?? .none
        exercises = try container.decodeIfPresent([Exercise].self, forKey: .exercises)
        lastFiredAt = try container.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        lastAcknowledgedAt = try container.decodeIfPresent(
            Date.self, forKey: .lastAcknowledgedAt
        )
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Records that a reminder fired and what the user did about it.
public struct ReminderEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case fired
        case completed
        case snoozed
        case dismissed
        case missed
    }

    public var id: UUID
    public var reminderID: UUID
    public var reminderTitle: String
    public var date: Date
    public var outcome: Outcome

    public init(
        id: UUID = UUID(),
        reminderID: UUID,
        reminderTitle: String,
        date: Date = Date(),
        outcome: Outcome
    ) {
        self.id = id
        self.reminderID = reminderID
        self.reminderTitle = reminderTitle
        self.date = date
        self.outcome = outcome
    }
}

/// A window of the day/week during which reminders are suppressed.
public struct QuietHours: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    /// Critical reminders can be allowed to pierce quiet hours, since for some
    /// users (like pressure-relief) they are medically necessary.
    public var allowsCritical: Bool

    public init(
        isEnabled: Bool = false,
        startHour: Int = 22,
        startMinute: Int = 0,
        endHour: Int = 7,
        endMinute: Int = 0,
        allowsCritical: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.allowsCritical = allowsCritical
    }

    /// True when `date` falls inside the quiet window. Handles windows that
    /// wrap past midnight (e.g. 22:00 → 07:00).
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return false }
        let now = hour * 60 + minute
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute
        if start == end { return false }
        if start < end {
            return now >= start && now < end
        }
        // Wraps midnight.
        return now >= start || now < end
    }

    /// The moment the quiet window containing `date` ends. Only meaningful when
    /// `contains(date)` is true; used to show when a suppressed reminder will
    /// actually surface.
    public func nextEnd(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        guard let endToday = calendar.date(
            bySettingHour: endHour, minute: endMinute, second: 0, of: date
        ) else { return nil }
        if endToday > date { return endToday }
        // Inside a window that wraps past midnight: the end is tomorrow.
        return calendar.date(byAdding: .day, value: 1, to: endToday)
    }
}

/// Global app preferences.
public struct Settings: Codable, Equatable, Sendable {
    public var quietHours: QuietHours
    /// Master switch. When paused, nothing fires.
    public var isPaused: Bool
    /// When set, the app is paused until this date, then resumes automatically.
    public var pausedUntil: Date?
    /// Minutes added when the user snoozes a reminder.
    public var snoozeMinutes: Int
    /// Seconds a subtle reminder stays on screen before self-dismissing.
    public var subtleDisplaySeconds: Int
    public var launchAtLogin: Bool
    /// Show a countdown to the next reminder in the menu bar.
    public var showsNextReminderInMenuBar: Bool
    /// Play sound for important/critical tiers.
    public var soundEnabled: Bool
    /// The playlist reminders set to "default" will play, as a canonical
    /// `spotify:playlist:ID` URI. `nil` means none is configured yet.
    public var defaultPlaylistURI: String?
    /// Master switch for music, independent of the per-reminder choice.
    ///
    /// Separate from clearing the playlist so a user can silence every reminder
    /// at once — during a meeting, say — without losing the playlist they
    /// picked and the per-reminder settings around it.
    public var musicEnabled: Bool
    /// Volume to fade Spotify up to when a reminder starts music, 0–100.
    /// Applied as a gentle ramp so a relaxation prompt does not blast whatever
    /// volume Spotify was last left at.
    public var musicVolume: Int

    public init(
        quietHours: QuietHours = QuietHours(),
        isPaused: Bool = false,
        pausedUntil: Date? = nil,
        snoozeMinutes: Int = 5,
        subtleDisplaySeconds: Int = 8,
        launchAtLogin: Bool = false,
        showsNextReminderInMenuBar: Bool = true,
        soundEnabled: Bool = true,
        defaultPlaylistURI: String? = nil,
        musicEnabled: Bool = true,
        musicVolume: Int = 55
    ) {
        self.quietHours = quietHours
        self.isPaused = isPaused
        self.pausedUntil = pausedUntil
        self.snoozeMinutes = snoozeMinutes
        self.subtleDisplaySeconds = subtleDisplaySeconds
        self.launchAtLogin = launchAtLogin
        self.showsNextReminderInMenuBar = showsNextReminderInMenuBar
        self.soundEnabled = soundEnabled
        self.defaultPlaylistURI = defaultPlaylistURI
        self.musicEnabled = musicEnabled
        self.musicVolume = musicVolume
    }

    /// Decodes the music fields as optional, so settings written before the
    /// music feature existed still load instead of throwing and resetting every
    /// preference to its default. See `Reminder.init(from:)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quietHours = try container.decode(QuietHours.self, forKey: .quietHours)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        snoozeMinutes = try container.decode(Int.self, forKey: .snoozeMinutes)
        subtleDisplaySeconds = try container.decode(Int.self, forKey: .subtleDisplaySeconds)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showsNextReminderInMenuBar = try container.decode(
            Bool.self, forKey: .showsNextReminderInMenuBar
        )
        soundEnabled = try container.decode(Bool.self, forKey: .soundEnabled)
        defaultPlaylistURI = try container.decodeIfPresent(
            String.self, forKey: .defaultPlaylistURI
        )
        musicEnabled = try container.decodeIfPresent(Bool.self, forKey: .musicEnabled) ?? true
        musicVolume = try container.decodeIfPresent(Int.self, forKey: .musicVolume) ?? 55
    }

    /// Whether a reminder of `priority` makes a sound when it fires: only the
    /// important and critical tiers, and only while the master switch is on.
    /// Subtle and normal stay silent so a busy reminder set does not become a
    /// stream of chimes.
    ///
    /// One place decides this for every surface on every platform — the
    /// notification, the overlay, the in-app takeover — so the policy cannot
    /// drift between them.
    public func playsSound(for priority: Priority) -> Bool {
        soundEnabled && priority >= .important
    }

    /// The playlist `reminder` should start when it fires, or `nil` for silence.
    ///
    /// One place decides this, so the master switch and the per-reminder choice
    /// cannot drift apart between the settings UI and the firing path.
    public func playlistURI(for reminder: Reminder) -> String? {
        guard musicEnabled else { return nil }
        return reminder.music.resolvedURI(defaultPlaylistURI: defaultPlaylistURI)
    }
}
