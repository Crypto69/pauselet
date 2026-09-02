import SwiftUI
import ReminderCore
import ReminderUI

/// Create or edit a reminder — the ported macOS `ReminderEditor`, with native
/// `DatePicker`s in place of the Mac's stepper-corrected time fields.
///
/// The schedule kinds stay a segmented choice: "every N minutes" and "at 5pm
/// every 2 days" are genuinely different mental models and mixing them into
/// one control confuses both.
///
/// An exercise reminder carries a list of exercises typed in here and is
/// always Critical: the list only makes sense on the full-screen takeover, so
/// the Importance picker gives way to a locked row while that type is
/// selected.
struct ReminderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let existing: Reminder?
    private let onSave: (Reminder) -> Void

    @State private var title: String
    @State private var message: String
    @State private var priority: Priority
    @State private var symbolName: String
    @State private var scheduleKind: ScheduleKind
    @State private var intervalMinutes: Int
    @State private var time: Date
    @State private var dayInterval: Int
    @State private var weekdays: Set<Int>
    @State private var hasActivityDuration: Bool
    @State private var activityMinutes: Int
    @State private var soundName: String?
    @State private var usesCustomDisplaySeconds: Bool
    @State private var displaySeconds: Int
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
        _type = State(initialValue: reminder?.isExercise == true ? .exercise : .standard)
        _exercises = State(initialValue: reminder?.exercises ?? [])

        let duration = reminder?.activityDurationSeconds
        _hasActivityDuration = State(initialValue: duration != nil)
        _activityMinutes = State(initialValue: max(1, (duration ?? 300) / 60))

        // Seed every schedule control with a sensible default, then override
        // the ones the existing reminder's schedule applies to, so switching
        // kinds in the picker never lands on an empty or nonsensical state.
        func timeDate(hour: Int, minute: Int) -> Date {
            Calendar.current.date(
                bySettingHour: hour, minute: minute, second: 0, of: Date()
            ) ?? Date()
        }

        var scheduleKind = ScheduleKind.interval
        var intervalMinutes = reminder == nil ? 30 : 60
        var time = timeDate(hour: 9, minute: 0)
        var dayInterval = 1
        var weekdays: Set<Int> = [2, 3, 4, 5, 6]

        switch reminder?.schedule {
        case .interval(let minutes):
            intervalMinutes = minutes
        case .dailyAt(let hour, let minute, let interval):
            scheduleKind = .daily
            time = timeDate(hour: hour, minute: minute)
            dayInterval = interval
        case .weeklyAt(let hour, let minute, let days):
            scheduleKind = .weekly
            time = timeDate(hour: hour, minute: minute)
            weekdays = days
        case nil:
            break
        }

        _scheduleKind = State(initialValue: scheduleKind)
        _intervalMinutes = State(initialValue: intervalMinutes)
        _time = State(initialValue: time)
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
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        switch scheduleKind {
        case .interval:
            return .interval(minutes: max(1, intervalMinutes))
        case .daily:
            return .dailyAt(hour: hour, minute: minute, dayInterval: max(1, dayInterval))
        case .weekly:
            return .weeklyAt(hour: hour, minute: minute, weekdays: weekdays)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(ReminderType.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("editorType")
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("editorTitle")
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("editorMessage")
                    SymbolPicker(selection: $symbolName)
                } footer: {
                    if type == .exercise {
                        Text("Lists the exercises to work through. Exercise reminders are always Critical.")
                    }
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
                        DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                        Stepper(
                            dayInterval == 1 ? "Every day" : "Every \(dayInterval) days",
                            value: $dayInterval,
                            in: 1...30
                        )
                    case .weekly:
                        DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                        WeekdayPicker(selection: $weekdays)
                    }

                    Text(composedSchedule.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Importance") {
                    if type == .exercise {
                        lockedCriticalRow
                    } else {
                        priorityRows
                    }

                    if effectivePriority >= .important {
                        Picker(
                            "Sound",
                            selection: Binding(
                                get: { soundName ?? "" },
                                set: {
                                    soundName = $0.isEmpty ? nil : $0
                                    if let name = soundName { Sounds.play(named: name) }
                                }
                            )
                        ) {
                            Text("Default").tag("")
                            ForEach(Sounds.available, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                }

                if effectivePriority == .subtle {
                    onScreenTimeSection
                }

                Section("Activity Timer") {
                    HelpRow(
                        title: "Run a countdown",
                        help: "Shows a timer for activities with a set length, "
                            + "such as tilting back for five minutes."
                    ) {
                        Toggle("", isOn: $hasActivityDuration).labelsHidden()
                    }
                    if hasActivityDuration {
                        Stepper(
                            "For \(activityMinutes) min",
                            value: $activityMinutes,
                            in: 1...120
                        )
                    }
                }

                Section {
                    Button {
                        model.preview(draft)
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .accessibilityHint("Shows this reminder now, exactly as it will appear")
                } footer: {
                    Text("Preview shows the reminder without touching its schedule or history.")
                }
            }
            .onChange(of: type) { _, newType in
                guard newType == .exercise else { return }
                // The shape of a row is the explanation, so never show an
                // empty list; and a reminder that is about exercise should
                // not keep the placeholder bell.
                if exercises.isEmpty {
                    exercises.append(Exercise(name: ""))
                }
                if symbolName == "bell" {
                    symbolName = "dumbbell.fill"
                }
            }
            .navigationTitle(existing == nil ? "New Reminder" : "Edit Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { save() }
                        .disabled(!isValid)
                        .accessibilityIdentifier("editorSave")
                }
            }
        }
    }

    /// The Exercise type's stand-in for the tier list: Critical, and why.
    private var lockedCriticalRow: some View {
        HStack(spacing: 10) {
            Image(systemName: Priority.critical.symbolName)
                .frame(width: 24)
                .foregroundStyle(PriorityDot.color(for: .critical))
            VStack(alignment: .leading, spacing: 2) {
                Text(Priority.critical.displayName)
                Text(
                    "Exercise reminders always take over the screen, so the "
                    + "list is in front of you while you work through it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var priorityRows: some View {
        ForEach(Priority.allCases, id: \.self) { level in
            Button {
                priority = level
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: level.symbolName)
                        .frame(width: 24)
                        .foregroundStyle(PriorityDot.color(for: level))
                    // Concrete colors: inside a Button label the
                    // hierarchical .primary/.secondary resolve
                    // against the accent tint, not the label color.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(level.displayName)
                            .foregroundStyle(Color.primary)
                        Text(explanation(for: level))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    if priority == level {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .fontWeight(.semibold)
                    }
                }
            }
            .accessibilityAddTraits(priority == level ? [.isSelected] : [])
        }
    }

    private var onScreenTimeSection: some View {
        Section("On-screen Time") {
            HelpRow(
                title: "Use a custom display time",
                help: "How long this card stays on screen before "
                    + "fading, when it appears inside the app. Turn "
                    + "on and increase it if the message is long, or "
                    + "if you need longer to read it."
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
    }

    /// iOS has no "menu bar" to be subtle near; the copy adapts while the
    /// tiers keep their meaning.
    private func explanation(for level: Priority) -> String {
        switch level {
        case .subtle:
            return "Silent. Straight to Notification Center; a quiet card in-app."
        case .normal:
            return "Standard notification, no sound."
        case .important:
            return "Notification with sound; breaks through Focus modes that allow it."
        case .critical:
            return "A real alarm: full screen, pierces Silent mode, stays until acknowledged."
        }
    }

    /// The reminder as currently configured, so Preview shows the unsaved
    /// edits rather than what is on disk.
    private var draft: Reminder {
        composed(from: existing ?? Reminder(title: "", schedule: composedSchedule))
    }

    private func composed(from base: Reminder) -> Reminder {
        var reminder = base
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        reminder.title = trimmed.isEmpty ? "Untitled reminder" : trimmed
        reminder.message = message.trimmingCharacters(in: .whitespaces)
        reminder.schedule = composedSchedule
        reminder.priority = effectivePriority
        reminder.symbolName = symbolName
        reminder.soundName = soundName
        reminder.displaySeconds = usesCustomDisplaySeconds ? displaySeconds : nil
        reminder.activityDurationSeconds = hasActivityDuration ? activityMinutes * 60 : nil
        // Tidied (trimmed, line endings unified, empty collapsed to nil) so
        // the same list serializes identically on every platform.
        reminder.exercises = type == .exercise ? Exercise.normalized(exercises) : nil
        return reminder
    }

    private func save() {
        var reminder = composed(from: existing ?? Reminder(title: "", schedule: composedSchedule))
        reminder.title = title.trimmingCharacters(in: .whitespaces)
        onSave(reminder)
        dismiss()
    }
}

/// Toggle buttons for the days of the week.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
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
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                spacing: 6
            ) {
                ForEach(EditorCatalog.symbols, id: \.self) { symbol in
                    let isSelected = symbol == selection
                    Button {
                        selection = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 17))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        isSelected
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.12)
                                    )
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}
