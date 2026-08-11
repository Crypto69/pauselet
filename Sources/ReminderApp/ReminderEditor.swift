import SwiftUI
import ReminderCore

/// Create or edit a reminder.
///
/// The schedule kinds are presented as a segmented choice rather than a single
/// free-form field, because "every N minutes" and "at 5pm every 2 days" are
/// genuinely different mental models and mixing them into one control confuses
/// both.
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

        let duration = reminder?.activityDurationSeconds
        _hasActivityDuration = State(initialValue: duration != nil)
        _activityMinutes = State(initialValue: max(1, (duration ?? 300) / 60))

        // Seed every schedule control from the existing reminder where it
        // applies, and with sensible defaults elsewhere, so switching kinds in
        // the picker never lands on an empty or nonsensical state.
        switch reminder?.schedule {
        case .interval(let minutes):
            _scheduleKind = State(initialValue: .interval)
            _intervalMinutes = State(initialValue: minutes)
            _timeHour = State(initialValue: 9)
            _timeMinute = State(initialValue: 0)
            _dayInterval = State(initialValue: 1)
            _weekdays = State(initialValue: [2, 3, 4, 5, 6])
        case .dailyAt(let hour, let minute, let interval):
            _scheduleKind = State(initialValue: .daily)
            _intervalMinutes = State(initialValue: 60)
            _timeHour = State(initialValue: hour)
            _timeMinute = State(initialValue: minute)
            _dayInterval = State(initialValue: interval)
            _weekdays = State(initialValue: [2, 3, 4, 5, 6])
        case .weeklyAt(let hour, let minute, let days):
            _scheduleKind = State(initialValue: .weekly)
            _intervalMinutes = State(initialValue: 60)
            _timeHour = State(initialValue: hour)
            _timeMinute = State(initialValue: minute)
            _dayInterval = State(initialValue: 1)
            _weekdays = State(initialValue: days)
        case nil:
            _scheduleKind = State(initialValue: .interval)
            _intervalMinutes = State(initialValue: 30)
            _timeHour = State(initialValue: 9)
            _timeMinute = State(initialValue: 0)
            _dayInterval = State(initialValue: 1)
            _weekdays = State(initialValue: [2, 3, 4, 5, 6])
        }
    }

    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if scheduleKind == .weekly && weekdays.isEmpty { return false }
        return true
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
                        TextField("Title", text: $title)
                        TextField("Message", text: $message, axis: .vertical)
                            .lineLimit(2...4)
                        SymbolPicker(selection: $symbolName)
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

                        if priority >= .important {
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
                    }

                    if priority == .subtle {
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
                    } else if priority == .normal || priority == .important {
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
        // typical display. The ScrollView still handles smaller screens.
        .frame(width: 470, height: 760)
    }

    /// The reminder as currently configured, so Preview shows the unsaved edits
    /// rather than what is on disk.
    private var draft: Reminder {
        var reminder = existing ?? Reminder(title: "", schedule: composedSchedule)
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        reminder.title = trimmed.isEmpty ? "Untitled reminder" : trimmed
        reminder.message = message.trimmingCharacters(in: .whitespaces)
        reminder.schedule = composedSchedule
        reminder.priority = priority
        reminder.symbolName = symbolName
        reminder.soundName = soundName
        reminder.displaySeconds = usesCustomDisplaySeconds ? displaySeconds : nil
        reminder.activityDurationSeconds = hasActivityDuration
            ? activityMinutes * 60
            : nil
        return reminder
    }

    private func save() {
        var reminder = existing ?? Reminder(title: "", schedule: composedSchedule)
        reminder.title = title.trimmingCharacters(in: .whitespaces)
        reminder.message = message.trimmingCharacters(in: .whitespaces)
        reminder.schedule = composedSchedule
        reminder.priority = priority
        reminder.symbolName = symbolName
        reminder.soundName = soundName
        reminder.displaySeconds = usesCustomDisplaySeconds ? displaySeconds : nil
        reminder.activityDurationSeconds = hasActivityDuration
            ? activityMinutes * 60
            : nil
        onSave(reminder)
        dismiss()
    }
}

/// Common intervals as presets, with a custom escape hatch.
struct IntervalPicker: View {
    @Binding var minutes: Int

    private static let presets = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Every", selection: Binding(
                get: { Self.presets.contains(minutes) ? minutes : -1 },
                set: { if $0 != -1 { minutes = $0 } }
            )) {
                ForEach(Self.presets, id: \.self) { preset in
                    Text(Schedule.humanDuration(minutes: preset)).tag(preset)
                }
                Text("Custom").tag(-1)
            }

            if !Self.presets.contains(minutes) {
                Stepper("Every \(minutes) min", value: $minutes, in: 1...1440, step: 5)
            }
        }
    }
}

/// Toggle buttons for the days of the week.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    // Calendar weekday numbering: 1 = Sunday ... 7 = Saturday.
    private static let days: [(number: Int, label: String)] = [
        (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S"),
    ]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Self.days, id: \.number) { day in
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
            }
        }
    }
}

/// A compact grid of SF Symbols relevant to health and routine reminders.
struct SymbolPicker: View {
    @Binding var selection: String

    private static let symbols = [
        "bell", "figure.seated.side", "arrow.up.and.down.circle", "drop.fill",
        "figure.flexibility", "figure.walk", "pills.fill", "heart.fill",
        "lungs.fill", "eye.fill", "hand.raised.fill", "fork.knife",
        "moon.fill", "sun.max.fill", "phone.fill", "book.fill",
        "cross.case.fill", "dumbbell.fill", "timer", "wind",
    ]

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 5), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Self.symbols, id: \.self) { symbol in
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
