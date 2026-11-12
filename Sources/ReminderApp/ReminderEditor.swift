import SwiftUI
import ReminderCore
import ReminderUI

/// Create or edit a reminder.
///
/// The schedule kinds are presented as a segmented choice rather than a single
/// free-form field, because "every N minutes" and "at 5pm every 2 days" are
/// genuinely different mental models and mixing them into one control confuses
/// both.
///
/// An exercise reminder carries a list of exercises typed in here and is
/// always Critical: the list only makes sense on the full-screen overlay, so
/// the Importance picker gives way to a note while that type is selected.
struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.previewReminder) private var previewReminder

    private let existing: Reminder?
    private let onSave: (Reminder) -> Void
    /// For the quiet-hours warning under a daily or weekly time.
    private let settings: ReminderCore.Settings

    @State private var title: String
    @State private var message: String
    @State private var priority: Priority
    @State private var symbolName: String
    @State private var scheduleKind: ScheduleKind
    @State private var intervalMinutes: Int
    @State private var timeHour: Int
    @State private var timeMinute: Int
    @State private var dayInterval: Int
    @State private var weekdays: Set<Int>
    /// Repeating on a clock grid (`.timedInterval`) rather than from the last
    /// fire. `timeHour`/`timeMinute` are the grid's start.
    @State private var hasStartTime: Bool
    @State private var hasEndTime: Bool
    @State private var endHour: Int
    @State private var endMinute: Int
    @State private var hasActivityDuration: Bool
    @State private var hasWarning: Bool
    @State private var warningMinutes: Int
    @State private var warningPlaysSound: Bool
    @State private var warningSoundName: String?
    @State private var activityMinutes: Int
    @State private var soundName: String?
    @State private var isSilent: Bool
    @State private var usesCustomDisplaySeconds: Bool
    @State private var displaySeconds: Int
    @State private var music: MusicChoice
    @State private var type: ReminderType
    @State private var exercises: [Exercise]
    @State private var restBetweenExercisesSeconds: Int

    enum ReminderType: String, CaseIterable, Identifiable {
        case standard, exercise
        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "Standard"
            case .exercise: return "Exercise"
            }
        }
    }

    enum ScheduleKind: String, CaseIterable, Identifiable {
        case interval, daily, weekly
        var id: String { rawValue }

        var title: String {
            switch self {
            case .interval: return "Repeating"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }
    }

    init(
        reminder: Reminder?,
        settings: ReminderCore.Settings = ReminderCore.Settings(),
        onSave: @escaping (Reminder) -> Void
    ) {
        self.existing = reminder
        self.settings = settings
        self.onSave = onSave

        _title = State(initialValue: reminder?.title ?? "")
        _message = State(initialValue: reminder?.message ?? "")
        _priority = State(initialValue: reminder?.priority ?? .normal)
        _symbolName = State(initialValue: reminder?.symbolName ?? "bell")
        _soundName = State(initialValue: reminder?.soundName)
        _isSilent = State(initialValue: reminder?.isSilent == true)
        _usesCustomDisplaySeconds = State(initialValue: reminder?.displaySeconds != nil)
        _displaySeconds = State(initialValue: reminder?.displaySeconds ?? 8)
        _music = State(initialValue: reminder?.music ?? .none)
        _type = State(initialValue: reminder?.isExercise == true ? .exercise : .standard)
        _exercises = State(initialValue: reminder?.exercises ?? [])
        _restBetweenExercisesSeconds = State(
            initialValue: reminder?.restBetweenExercisesSeconds ?? 0
        )

        _hasWarning = State(initialValue: reminder?.warningMinutes != nil)
        _warningMinutes = State(initialValue: reminder?.warningMinutes ?? 5)
        _warningPlaysSound = State(initialValue: reminder?.warningIsSilent != true)
        _warningSoundName = State(initialValue: reminder?.warningSoundName)

        let duration = reminder?.activityDurationSeconds
        _hasActivityDuration = State(initialValue: duration != nil)
        _activityMinutes = State(initialValue: max(1, (duration ?? 300) / 60))

        // Seed every schedule control with a sensible default, then override
        // the ones the existing reminder's schedule applies to, so switching
        // kinds in the picker never lands on an empty or nonsensical state.
        var scheduleKind = ScheduleKind.interval
        var intervalMinutes = reminder == nil ? 30 : 60
        var timeHour = 9
        var timeMinute = 0
        var dayInterval = 1
        var weekdays: Set<Int> = [2, 3, 4, 5, 6]
        var hasStartTime = false
        var hasEndTime = false
        var endHour = 17
        var endMinute = 0

        switch reminder?.schedule {
        case .interval(let minutes):
            intervalMinutes = minutes
        case .timedInterval(let minutes, let startHour, let startMinute,
                            let untilHour, let untilMinute, let days):
            intervalMinutes = minutes
            hasStartTime = true
            timeHour = startHour
            timeMinute = startMinute
            if let untilHour, let untilMinute {
                hasEndTime = true
                endHour = untilHour
                endMinute = untilMinute
            }
            weekdays = days
        case .dailyAt(let hour, let minute, let interval):
            scheduleKind = .daily
            timeHour = hour
            timeMinute = minute
            dayInterval = interval
        case .weeklyAt(let hour, let minute, let days):
            scheduleKind = .weekly
            timeHour = hour
            timeMinute = minute
            weekdays = days
        case nil:
            break
        }

        _scheduleKind = State(initialValue: scheduleKind)
        _intervalMinutes = State(initialValue: intervalMinutes)
        _timeHour = State(initialValue: timeHour)
        _timeMinute = State(initialValue: timeMinute)
        _dayInterval = State(initialValue: dayInterval)
        _weekdays = State(initialValue: weekdays)
        _hasStartTime = State(initialValue: hasStartTime)
        _hasEndTime = State(initialValue: hasEndTime)
        _endHour = State(initialValue: endHour)
        _endMinute = State(initialValue: endMinute)
    }

    /// A timed interval's end must come after its start: the grid does not
    /// run past midnight.
    private var endIsBeforeStart: Bool {
        scheduleKind == .interval && hasStartTime && hasEndTime
            && endHour * 60 + endMinute <= timeHour * 60 + timeMinute
    }

    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if scheduleKind == .weekly && weekdays.isEmpty { return false }
        if scheduleKind == .interval && hasStartTime && weekdays.isEmpty { return false }
        if endIsBeforeStart { return false }
        if type == .exercise && (exercises.isEmpty || !exercises.allSatisfy(\.isValid)) {
            return false
        }
        return true
    }

    /// The tier the reminder will actually have. The radio picker keeps the
    /// user's choice while the Exercise type imposes Critical on top of it, so
    /// switching to Exercise and back within one editing session leaves the
    /// picked tier alone. (A saved exercise reminder is Critical on disk, so
    /// reopening it and switching back shows Critical selected — visibly, in
    /// the picker, where it can be changed.)
    private var effectivePriority: Priority {
        type == .exercise ? .critical : priority
    }

    private var composedSchedule: Schedule {
        switch scheduleKind {
        case .interval where hasStartTime:
            return .timedInterval(
                minutes: max(1, intervalMinutes),
                startHour: timeHour,
                startMinute: timeMinute,
                endHour: hasEndTime ? endHour : nil,
                endMinute: hasEndTime ? endMinute : nil,
                weekdays: weekdays
            )
        case .interval:
            return .interval(minutes: max(1, intervalMinutes))
        case .daily:
            return .dailyAt(
                hour: timeHour, minute: timeMinute, dayInterval: max(1, dayInterval)
            )
        case .weekly:
            return .weeklyAt(hour: timeHour, minute: timeMinute, weekdays: weekdays)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "New Reminder" : "Edit Reminder")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                Form {
                    Section {
                        Picker("Type", selection: $type) {
                            ForEach(ReminderType.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("Title", text: $title)
                        TextField("Message", text: $message, axis: .vertical)
                            .lineLimit(2...4)
                        SymbolPicker(selection: $symbolName)
                    }

                    if type == .exercise {
                        ExerciseListSection(
                            exercises: $exercises,
                            restBetweenExercisesSeconds: $restBetweenExercisesSeconds
                        )
                    }

                    Section("Schedule") {
                        Picker("Repeats", selection: $scheduleKind) {
                            ForEach(ScheduleKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch scheduleKind {
                        case .interval:
                            IntervalPicker(minutes: $intervalMinutes)
                            HelpRow(
                                title: "Start at a set time",
                                help: "Repeat on a fixed timetable — from a start "
                                    + "time, on the days you pick — instead of "
                                    + "counting from when the reminder last "
                                    + "fired. Useful for keeping in step with "
                                    + "another app's breaks."
                            ) {
                                Toggle("", isOn: $hasStartTime)
                                    .labelsHidden()
                            }
                            if hasStartTime {
                                TimeField("From", hour: $timeHour, minute: $timeMinute)
                                Toggle("End at a set time", isOn: $hasEndTime)
                                if hasEndTime {
                                    TimeField("Until", hour: $endHour, minute: $endMinute)
                                }
                                WeekdayPicker(selection: $weekdays)
                                if endIsBeforeStart {
                                    Label(
                                        "The end time must be after the start time.",
                                        systemImage: "exclamationmark.circle"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                }
                            }
                        case .daily:
                            TimeField("At", hour: $timeHour, minute: $timeMinute)
                            Stepper(
                                dayInterval == 1
                                    ? "Every day"
                                    : "Every \(dayInterval) days",
                                value: $dayInterval,
                                in: 1...30
                            )
                        case .weekly:
                            TimeField("At", hour: $timeHour, minute: $timeMinute)
                            WeekdayPicker(selection: $weekdays)
                        }

                        Text(composedSchedule.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let warning = quietHoursWarning {
                            Label(warning, systemImage: "moon.zzz")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Importance") {
                        if type == .exercise {
                            HStack(spacing: 6) {
                                Image(systemName: Priority.critical.symbolName)
                                    .foregroundStyle(PriorityDot.color(for: .critical))
                                Text(Priority.critical.displayName)
                            }
                            Text(
                                "Exercise reminders always take over every display, "
                                + "so the list is in front of you while you work "
                                + "through it."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Picker("Priority", selection: $priority) {
                                ForEach(Priority.allCases, id: \.self) { level in
                                    HStack {
                                        Image(systemName: level.symbolName)
                                            .foregroundStyle(PriorityDot.color(for: level))
                                        Text(level.displayName)
                                    }
                                    .tag(level)
                                }
                            }
                            .pickerStyle(.radioGroup)

                            Text(priority.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if effectivePriority >= .important {
                            soundPicker
                        }
                    }

                    if effectivePriority == .subtle {
                        Section("On-screen Time") {
                            HelpRow(
                                title: "Use a custom display time",
                                help: "How long this card stays on screen before "
                                    + "fading. Turn on and increase it if the "
                                    + "message is long, or if you need longer to "
                                    + "read it."
                            ) {
                                Toggle("", isOn: $usesCustomDisplaySeconds)
                                    .labelsHidden()
                            }
                            if usesCustomDisplaySeconds {
                                Stepper(
                                    "Stay on screen for \(displaySeconds)s",
                                    value: $displaySeconds,
                                    in: 2...120
                                )
                            }
                        }
                    } else if effectivePriority == .normal || effectivePriority == .important {
                        Section("On-screen Time") {
                            Text(
                                "macOS controls how long a notification banner "
                                + "stays up. To keep it until you dismiss it, set "
                                + "Reminder to \"Alerts\" in System Settings › "
                                + "Notifications."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    ReminderMusicSection(music: $music)

                    // Only the Critical takeover draws the countdown, so the
                    // option is meaningless on any other tier and is hidden
                    // rather than silently ignored.
                    if effectivePriority == .critical {
                        Section("Activity Timer") {
                            Toggle("Run a countdown", isOn: $hasActivityDuration)
                                .help(
                                    "Show a timer on the full-screen takeover for "
                                        + "activities with a set length, such as "
                                        + "tilting back for five minutes."
                                )
                            if hasActivityDuration {
                                Stepper(
                                    "For \(activityMinutes) min",
                                    value: $activityMinutes,
                                    in: 1...120
                                )
                            }
                        }

                        ReminderWarningSection(
                            hasWarning: $hasWarning,
                            minutes: $warningMinutes,
                            playsSound: $warningPlaysSound,
                            soundName: $warningSoundName,
                            schedule: composedSchedule
                        )
                    }
                }
                .formStyle(.grouped)
                .onChange(of: type) { newType in
                    guard newType == .exercise else { return }
                    // The shape of a row is the explanation, so never show an
                    // empty list; and a reminder that is about exercise
                    // should not keep the placeholder bell.
                    if exercises.isEmpty {
                        exercises.append(Exercise(name: ""))
                    }
                    if symbolName == "bell" {
                        symbolName = "dumbbell.fill"
                    }
                }
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    previewReminder(draft)
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .help("Show this reminder now, exactly as it will appear")

                Spacer()
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        // Tall enough that the whole form — including all four priority options,
        // which are the point of the app — is visible without scrolling on a
        // typical display. The ScrollView still handles smaller screens, and
        // an exercise list of any length: the hidden tier picker roughly pays
        // for the first few rows, and the rest scroll.
        .frame(width: 470, height: 760)
    }

    /// The picker's tag for "None": not a sound name, so it can never
    /// collide with one. Stored as `isSilent`, never as a sound called None.
    private static let silentTag = "none"

    private var soundPicker: some View {
        Picker(
            "Sound",
            selection: Binding(
                get: { isSilent ? Self.silentTag : (soundName ?? "") },
                set: { choice in
                    isSilent = choice == Self.silentTag
                    soundName = choice.isEmpty || isSilent ? nil : choice
                }
            )
        ) {
            Text("Default").tag("")
            Text("None").tag(Self.silentTag)
            ForEach(Sounds.available, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .help(
            "None keeps this reminder silent even while sounds are on, "
                + "including the chime when its timer ends. The voice coach "
                + "has its own setting."
        )
        .onChange(of: soundName) { newValue in
            if let newValue { Sounds.play(named: newValue) }
        }
    }

    /// The music choice as it should be stored.
    ///
    /// Choosing "its own playlist" and then never pasting a link leaves an
    /// empty URI behind. Saving that as `.playlist(uri: "")` would give the
    /// reminder a music setting that can never play anything, so it collapses
    /// to "no music" instead.
    private var normalizedMusic: MusicChoice {
        if case .playlist(let uri) = music,
           uri.trimmingCharacters(in: .whitespaces).isEmpty {
            return .none
        }
        return music
    }

    /// The exercise list as it should be stored: `nil` unless this is an
    /// exercise reminder, and tidied (trimmed, line endings unified, empty
    /// collapsed to `nil`) so the same list serializes identically on every
    /// platform.
    private var normalizedExercises: [Exercise]? {
        type == .exercise ? Exercise.normalized(exercises) : nil
    }

    /// The reminder as currently configured, so Preview shows the unsaved edits
    /// rather than what is on disk.
    private var draft: Reminder {
        compose(untitled: "Untitled reminder")
    }

    /// The single place the form's state becomes a `Reminder`, so Preview and
    /// Save can never disagree about a field.
    private func compose(untitled fallback: String) -> Reminder {
        var reminder = existing ?? Reminder(title: "", schedule: composedSchedule)
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        reminder.title = trimmed.isEmpty ? fallback : trimmed
        reminder.message = message.trimmingCharacters(in: .whitespaces)
        reminder.schedule = composedSchedule
        reminder.priority = effectivePriority
        reminder.symbolName = symbolName
        reminder.soundName = soundName
        // Only silence is written; the default (a sound) is left off the
        // reminder entirely, so an older build reads the file unchanged.
        reminder.isSilent = isSilent ? true : nil
        reminder.displaySeconds = usesCustomDisplaySeconds ? displaySeconds : nil
        reminder.music = normalizedMusic
        reminder.exercises = normalizedExercises
        // A rest only exists between exercises: stored as nil for an ordinary
        // reminder, for none, and for a single exercise (the field is hidden
        // then, so a stale value must not be saved behind the user's back).
        reminder.restBetweenExercisesSeconds =
            (normalizedExercises?.count ?? 0) > 1 && restBetweenExercisesSeconds > 0
                ? min(restBetweenExercisesSeconds, Exercise.restRange.upperBound)
                : nil
        // Cleared for any tier that cannot show it, so the data never carries
        // a timer the user can no longer see in the editor.
        reminder.activityDurationSeconds = effectivePriority == .critical && hasActivityDuration
            ? activityMinutes * 60
            : nil
        reminder.warningMinutes = effectivePriority == .critical && hasWarning
            ? min(max(warningMinutes, Self.warningRange.lowerBound), Self.warningRange.upperBound)
            : nil
        // Only a quiet warning is written; the default (a chime) is left off
        // the reminder entirely, as is any choice for a warning that is off.
        reminder.warningIsSilent = reminder.warningMinutes != nil && !warningPlaysSound
            ? true
            : nil
        // Likewise the sound: kept only for a warning that plays one.
        reminder.warningSoundName = reminder.warningMinutes != nil && warningPlaysSound
            ? warningSoundName
            : nil
        return reminder
    }

    private static let warningRange = Scheduler.warningMinutesRange

    /// A daily or weekly time inside quiet hours is skipped every time it
    /// comes round; better said here than discovered from a silent history.
    private var quietHoursWarning: String? {
        if case .timedInterval = composedSchedule {
            return Scheduler.timedIntervalQuietHoursWarning(
                composedSchedule, priority: effectivePriority, settings: settings
            )
        }
        guard scheduleKind != .interval,
              Scheduler.wallClockTimeIsSilenced(
                hour: timeHour, minute: timeMinute, priority: effectivePriority, settings: settings
              )
        else { return nil }
        let quiet = settings.quietHours
        return String(
            format: "Falls inside quiet hours (%02d:%02d–%02d:%02d), so it will be skipped.",
            quiet.startHour, quiet.startMinute, quiet.endHour, quiet.endMinute
        )
    }

    private func save() {
        onSave(compose(untitled: ""))
        dismiss()
    }
}

/// Toggle buttons for the days of the week.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 5) {
            ForEach(EditorCatalog.weekdays, id: \.number) { day in
                let isOn = selection.contains(day.number)
                Button {
                    if isOn {
                        selection.remove(day.number)
                    } else {
                        selection.insert(day.number)
                    }
                } label: {
                    Text(day.label)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 27)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.14))
                        )
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.name)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }
}

/// A compact grid of SF Symbols relevant to health and routine reminders.
struct SymbolPicker: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 5), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(EditorCatalog.symbols, id: \.self) { symbol in
                    let isSelected = symbol == selection
                    Button {
                        selection = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 15))
                            .frame(width: 32, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(
                                        isSelected
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.12)
                                    )
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The Critical tier's advance-warning controls: whether to warn, and how
/// many minutes ahead. Its own view so the snapshot harness can render it —
/// the editor fixes its height, and this sits below the fold.
struct ReminderWarningSection: View {
    @Binding var hasWarning: Bool
    @Binding var minutes: Int
    /// Whether the warning card chimes. Off gives a quiet heads-up; the
    /// takeover keeps its own sound either way.
    @Binding var playsSound: Bool
    /// The sound it plays; `nil` is the default chime.
    @Binding var soundName: String?
    /// The schedule being edited, to say when the lead outlasts its interval.
    let schedule: Schedule

    /// A warning as long as the repeat interval would have to come before
    /// the previous takeover, so none is shown; say so rather than leave the
    /// user waiting for a card that never comes.
    private var caution: String? {
        guard Scheduler.warningOutlastsInterval(minutes, schedule: schedule) else { return nil }
        return "That is as long as the repeat interval, so there is no time to "
            + "warn before each takeover."
    }

    var body: some View {
        Section("Warning") {
            Toggle("Warn me before it takes over", isOn: $hasWarning)
                .help(
                    "Show a card in the corner a set time before "
                        + "the full-screen takeover, so it never "
                        + "arrives unannounced."
                )
            if hasWarning {
                Stepper(value: $minutes, in: Scheduler.warningMinutesRange) {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: $minutes, format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 56)
                        .labelsHidden()
                        .accessibilityLabel("Minutes before")
                        Text(minutes == 1 ? "minute before" : "minutes before")
                    }
                }
                .onChange(of: minutes) { value in
                    let clamped = min(
                        max(value, Scheduler.warningMinutesRange.lowerBound),
                        Scheduler.warningMinutesRange.upperBound
                    )
                    if clamped != value { minutes = clamped }
                }
                Toggle("Play a sound with the warning", isOn: $playsSound)
                    .help(
                        "Turn off for a quiet heads-up. The takeover itself "
                            + "still plays its sound. Has no effect while "
                            + "sounds are off in Settings."
                    )
                if playsSound {
                    // The same list as the reminder's own sound, and the same
                    // habit: choosing one plays it.
                    Picker(
                        "Warning sound",
                        selection: Binding(
                            get: { soundName ?? "" },
                            set: { soundName = $0.isEmpty ? nil : $0 }
                        )
                    ) {
                        Text("Default (\(Scheduler.defaultWarningSound))").tag("")
                        ForEach(Sounds.available, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .onChange(of: soundName) { newValue in
                        Sounds.play(named: newValue ?? Scheduler.defaultWarningSound)
                    }
                }
                Text(
                    "A card appears in the top-right corner and stays "
                    + "until you tick it. Ticking it does not change "
                    + "when the takeover comes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let caution {
                    Label(caution, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
