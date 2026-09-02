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
    @State private var hasActivityDuration: Bool
    @State private var activityMinutes: Int
    @State private var soundName: String?
    @State private var usesCustomDisplaySeconds: Bool
    @State private var displaySeconds: Int
    @State private var music: MusicChoice
    @State private var type: ReminderType
    @State private var exercises: [Exercise]

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

    init(reminder: Reminder?, onSave: @escaping (Reminder) -> Void) {
        self.existing = reminder
        self.onSave = onSave

        _title = State(initialValue: reminder?.title ?? "")
        _message = State(initialValue: reminder?.message ?? "")
        _priority = State(initialValue: reminder?.priority ?? .normal)
        _symbolName = State(initialValue: reminder?.symbolName ?? "bell")
        _soundName = State(initialValue: reminder?.soundName)
        _usesCustomDisplaySeconds = State(initialValue: reminder?.displaySeconds != nil)
        _displaySeconds = State(initialValue: reminder?.displaySeconds ?? 8)
        _music = State(initialValue: reminder?.music ?? .none)
        _type = State(initialValue: reminder?.isExercise == true ? .exercise : .standard)
        _exercises = State(initialValue: reminder?.exercises ?? [])

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

        switch reminder?.schedule {
        case .interval(let minutes):
            intervalMinutes = minutes
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
    }

    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if scheduleKind == .weekly && weekdays.isEmpty { return false }
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
                        ExerciseListSection(exercises: $exercises)
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
                        case .daily:
                            HStack {
                                Text("At")
                                TimeField(hour: $timeHour, minute: $timeMinute)
                            }
                            Stepper(
                                dayInterval == 1
                                    ? "Every day"
                                    : "Every \(dayInterval) days",
                                value: $dayInterval,
                                in: 1...30
                            )
                        case .weekly:
                            HStack {
                                Text("At")
                                TimeField(hour: $timeHour, minute: $timeMinute)
                            }
                            WeekdayPicker(selection: $weekdays)
                        }

                        Text(composedSchedule.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Importance") {
                        if type == .exercise {
                            HStack(spacing: 6) {
                                Image(systemName: Priority.critical.symbolName)
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

                    Section("Activity Timer") {
                        Toggle("Run a countdown", isOn: $hasActivityDuration)
                            .help(
                                "Show a timer for activities with a set length, "
                                    + "such as tilting back for five minutes."
                            )
                        if hasActivityDuration {
                            Stepper(
                                "For \(activityMinutes) min",
                                value: $activityMinutes,
                                in: 1...120
                            )
                        }
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

    private var soundPicker: some View {
        Picker(
            "Sound",
            selection: Binding(
                get: { soundName ?? "" },
                set: { soundName = $0.isEmpty ? nil : $0 }
            )
        ) {
            Text("Default").tag("")
            ForEach(Sounds.available, id: \.self) { name in
                Text(name).tag(name)
            }
        }
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
        reminder.displaySeconds = usesCustomDisplaySeconds ? displaySeconds : nil
        reminder.music = normalizedMusic
        reminder.exercises = normalizedExercises
        reminder.activityDurationSeconds = hasActivityDuration
            ? activityMinutes * 60
            : nil
        return reminder
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
