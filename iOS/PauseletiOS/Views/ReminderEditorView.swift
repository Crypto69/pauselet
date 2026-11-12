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
    /// Repeating on a clock grid (`.timedInterval`) rather than from the last
    /// fire. `time` is the grid's start.
    @State private var hasStartTime: Bool
    @State private var hasEndTime: Bool
    @State private var endTime: Date
    @State private var hasActivityDuration: Bool
    @State private var hasWarning: Bool
    @State private var warningMinutes: Int
    @State private var warningPlaysSound: Bool
    @State private var warningSoundName: String?
    @State private var activityMinutes: Int
    @State private var autoFinish: Bool
    @State private var dismissal: TakeoverDismissal
    @State private var soundName: String?
    @State private var isSilent: Bool
    @State private var usesCustomDisplaySeconds: Bool
    @State private var displaySeconds: Int
    @State private var type: ReminderType
    @State private var exercises: [Exercise]
    @State private var isImportingExercises = false
    @EnvironmentObject private var ai: AIImportController
    @State private var restBetweenExercisesSeconds: Int

    /// The sound picker's tag for "None": not a sound name, so it can never
    /// collide with one.
    private static let silentTag = "none"

    /// What each level means, said under the picker — with the one thing
    /// iOS cannot promise: the Home gesture always works, so the takeover
    /// follows the user to the Lock Screen instead of holding the phone.
    static func dismissalCaption(for level: TakeoverDismissal) -> String {
        switch level {
        case .anytime:
            return "Done and Snooze work at any time."
        case .snoozeOnly:
            return "Done waits for the timer. Snooze still works, and the reminder comes back."
        case .locked:
            return "Done and Snooze both wait for the timer. Leaving the app is always "
                + "possible; Pauselet keeps the reminder on the Lock Screen until the "
                + "timer ends."
        }
    }

    /// What None means on this tier, said where it is chosen. The Lock
    /// Screen alarm is AlarmKit's, which cannot be silent; Pauselet gives it
    /// a silent sound file instead, which is as quiet as iOS allows.
    private var silentCriticalFootnote: String {
        "The in-app takeover is silent. The Lock Screen alarm plays a silent "
            + "sound, so it may still vibrate."
    }

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
        _isSilent = State(initialValue: reminder?.isSilent == true)
        _usesCustomDisplaySeconds = State(initialValue: reminder?.displaySeconds != nil)
        _displaySeconds = State(initialValue: reminder?.displaySeconds ?? 8)
        _type = State(initialValue: reminder?.isExercise == true ? .exercise : .standard)
        _exercises = State(initialValue: reminder?.exercises ?? [])
        _restBetweenExercisesSeconds = State(
            initialValue: reminder?.restBetweenExercisesSeconds ?? 0
        )

        let duration = reminder?.activityDurationSeconds
        _hasActivityDuration = State(initialValue: duration != nil)
        _hasWarning = State(initialValue: reminder?.warningMinutes != nil)
        _warningMinutes = State(initialValue: reminder?.warningMinutes ?? 5)
        _warningPlaysSound = State(initialValue: reminder?.warningIsSilent != true)
        _warningSoundName = State(initialValue: reminder?.warningSoundName)
        _activityMinutes = State(initialValue: max(1, (duration ?? 300) / 60))
        _autoFinish = State(initialValue: reminder?.autoFinish == true)
        _dismissal = State(initialValue: reminder?.dismissal ?? .anytime)

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
        var hasStartTime = false
        var hasEndTime = false
        var endTime = timeDate(hour: 17, minute: 0)

        switch reminder?.schedule {
        case .interval(let minutes):
            intervalMinutes = minutes
        case .timedInterval(let minutes, let startHour, let startMinute,
                            let untilHour, let untilMinute, let days):
            intervalMinutes = minutes
            hasStartTime = true
            time = timeDate(hour: startHour, minute: startMinute)
            if let untilHour, let untilMinute {
                hasEndTime = true
                endTime = timeDate(hour: untilHour, minute: untilMinute)
            }
            weekdays = days
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
        _hasStartTime = State(initialValue: hasStartTime)
        _hasEndTime = State(initialValue: hasEndTime)
        _endTime = State(initialValue: endTime)
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// A timed interval's end must come after its start: the grid does not
    /// run past midnight.
    private var endIsBeforeStart: Bool {
        scheduleKind == .interval && hasStartTime && hasEndTime
            && Self.minuteOfDay(endTime) <= Self.minuteOfDay(time)
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
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        switch scheduleKind {
        case .interval where hasStartTime:
            let end = Self.minuteOfDay(endTime)
            return .timedInterval(
                minutes: max(1, intervalMinutes),
                startHour: hour,
                startMinute: minute,
                endHour: hasEndTime ? end / 60 : nil,
                endMinute: hasEndTime ? end % 60 : nil,
                weekdays: weekdays
            )
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
                    ExerciseListSection(
                            exercises: $exercises,
                            restBetweenExercisesSeconds: $restBetweenExercisesSeconds,
                            isImporting: $isImportingExercises
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
                        Toggle("Start at a set time", isOn: $hasStartTime.animation())
                            .accessibilityIdentifier("editorStartAtSetTime")
                        if hasStartTime {
                            DatePicker("From", selection: $time, displayedComponents: .hourAndMinute)
                            Toggle("End at a set time", isOn: $hasEndTime.animation())
                            if hasEndTime {
                                DatePicker(
                                    "Until", selection: $endTime, displayedComponents: .hourAndMinute
                                )
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
                    if let warning = quietHoursWarning {
                        Label(warning, systemImage: "moon.zzz")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Importance") {
                    if type == .exercise {
                        lockedCriticalRow
                    } else {
                        priorityRows
                    }

                    if effectivePriority >= .important {
                        // "None" is a row of the picker rather than a switch,
                        // stored as `isSilent` so it can never collide with
                        // a sound's name.
                        Picker(
                            "Sound",
                            selection: Binding(
                                get: { isSilent ? Self.silentTag : (soundName ?? "") },
                                set: { choice in
                                    isSilent = choice == Self.silentTag
                                    soundName = choice.isEmpty || isSilent ? nil : choice
                                    if let name = soundName { Sounds.play(named: name) }
                                }
                            )
                        ) {
                            Text("Default").tag("")
                            Text("None").tag(Self.silentTag)
                            ForEach(Sounds.available, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .accessibilityIdentifier("editorSound")
                        if isSilent, effectivePriority == .critical {
                            Text(silentCriticalFootnote)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if effectivePriority == .subtle {
                    onScreenTimeSection
                }

                // Only the Critical takeover draws the countdown; on other
                // tiers the option would be stored and never shown.
                if effectivePriority == .critical {
                    Section("Activity Timer") {
                        HelpRow(
                            title: "Run a countdown",
                            help: "Shows a timer on the full-screen takeover for "
                                + "activities with a set length, such as tilting "
                                + "back for five minutes."
                        ) {
                            Toggle("", isOn: $hasActivityDuration).labelsHidden()
                        }
                        if hasActivityDuration {
                            Stepper(
                                "For \(activityMinutes) min",
                                value: $activityMinutes,
                                in: 1...120
                            )
                            HelpRow(
                                title: "Finish automatically",
                                help: "Closes the takeover by itself when the "
                                    + "countdown reaches zero, as if you had tapped "
                                    + "Done — unless an exercise is being coached, "
                                    + "when it waits for you."
                            ) {
                                Toggle("", isOn: $autoFinish).labelsHidden()
                            }
                            .accessibilityIdentifier("editorAutoFinish")
                            Picker("Can be dismissed", selection: $dismissal) {
                                ForEach(TakeoverDismissal.allCases, id: \.self) { level in
                                    Text(level.title).tag(level)
                                }
                            }
                            .accessibilityIdentifier("editorDismissal")
                            Text(Self.dismissalCaption(for: dismissal))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        HelpRow(
                            title: "Warn me before it takes over",
                            help: "Sends a notification a set time before the "
                                + "full-screen takeover, so it never arrives "
                                + "unannounced."
                        ) {
                            Toggle("", isOn: $hasWarning.animation()).labelsHidden()
                        }
                        .accessibilityIdentifier("editorWarning")
                        if hasWarning {
                            Stepper(value: $warningMinutes, in: Scheduler.warningMinutesRange) {
                                HStack(spacing: 6) {
                                    TextField("", value: $warningMinutes, format: .number)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.trailing)
                                        .monospacedDigit()
                                        .frame(width: 56)
                                        .accessibilityLabel("Minutes before")
                                    Text(warningMinutes == 1 ? "minute before" : "minutes before")
                                }
                            }
                            .onChange(of: warningMinutes) { _, value in
                                let range = Scheduler.warningMinutesRange
                                let clamped = min(max(value, range.lowerBound), range.upperBound)
                                if clamped != value { warningMinutes = clamped }
                            }
                            HelpRow(
                                title: "Play a sound",
                                help: "Turn off for a quiet heads-up. The takeover "
                                    + "itself still plays its sound."
                            ) {
                                Toggle("", isOn: $warningPlaysSound.animation()).labelsHidden()
                            }
                            .accessibilityIdentifier("editorWarningSound")
                            if warningPlaysSound {
                                // The same list as the reminder's own sound,
                                // and choosing one plays it.
                                Picker(
                                    "Warning sound",
                                    selection: Binding(
                                        get: { warningSoundName ?? "" },
                                        set: {
                                            warningSoundName = $0.isEmpty ? nil : $0
                                            if let name = warningSoundName { Sounds.play(named: name) }
                                        }
                                    )
                                ) {
                                    Text("Default").tag("")
                                    ForEach(Sounds.available, id: \.self) { name in
                                        Text(name).tag(name)
                                    }
                                }
                                .accessibilityIdentifier("editorWarningSoundName")
                            }
                            if Scheduler.warningOutlastsInterval(
                                warningMinutes, schedule: composedSchedule
                            ) {
                                Label(
                                    "That is as long as the repeat interval, so there is "
                                        + "no time to warn before each takeover.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    } header: {
                        Text("Warning")
                    } footer: {
                        Text(
                            "A time-sensitive notification. To keep it on screen until "
                                + "you clear it, set Pauselet's banner style to "
                                + "Persistent in Settings › Notifications."
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
                    .accessibilityIdentifier("editorPreview")
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
            // Presented from the Form, not from the exercise Section: on iOS 26
            // a sheet attached inside a Form section of a presented sheet
            // dismisses that sheet rather than stacking on it.
            .sheet(isPresented: $isImportingExercises) {
                ExerciseImportSheet { imported in
                    // Switching the type to Exercise seeds one blank row for
                    // typing into. Importing is the alternative to typing, so
                    // that untouched placeholder is replaced rather than left
                    // above the imported rows. Anything actually filled in stays.
                    exercises.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                    exercises.append(contentsOf: imported)
                }
                // A sheet gets a fresh environment; the import controller has
                // to be handed to it explicitly.
                .environmentObject(ai)
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

    /// A daily or weekly time inside quiet hours is skipped every time it
    /// comes round; better said here than discovered from a silent history.
    private var quietHoursWarning: String? {
        if case .timedInterval = composedSchedule {
            return Scheduler.timedIntervalQuietHoursWarning(
                composedSchedule, priority: effectivePriority, settings: model.engine.settings
            )
        }
        guard scheduleKind != .interval else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard let hour = comps.hour, let minute = comps.minute,
              Scheduler.wallClockTimeIsSilenced(
                hour: hour, minute: minute, priority: effectivePriority,
                settings: model.engine.settings
              )
        else { return nil }
        let quiet = model.engine.settings.quietHours
        return String(
            format: "Falls inside quiet hours (%02d:%02d–%02d:%02d), so it will be skipped.",
            quiet.startHour, quiet.startMinute, quiet.endHour, quiet.endMinute
        )
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
        // Only silence is written; the default (a sound) is left off the
        // reminder entirely, so an older build reads the file unchanged.
        reminder.isSilent = isSilent ? true : nil
        reminder.displaySeconds = usesCustomDisplaySeconds ? displaySeconds : nil
        // Cleared for any tier that cannot show it (see the editor section).
        reminder.activityDurationSeconds =
            effectivePriority == .critical && hasActivityDuration ? activityMinutes * 60 : nil
        // Only ever written with a countdown, and only as true: the default
        // (wait for Done) is left off the reminder entirely.
        reminder.autoFinish = reminder.activityDurationSeconds != nil && autoFinish ? true : nil
        // Likewise the lock: only with a countdown, never as "any time".
        reminder.dismissal = reminder.activityDurationSeconds != nil && dismissal != .anytime
            ? dismissal
            : nil
        reminder.warningMinutes = effectivePriority == .critical && hasWarning
            ? min(
                max(warningMinutes, Scheduler.warningMinutesRange.lowerBound),
                Scheduler.warningMinutesRange.upperBound
            )
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
        // Tidied (trimmed, line endings unified, empty collapsed to nil) so
        // the same list serializes identically on every platform.
        reminder.exercises = type == .exercise ? Exercise.normalized(exercises) : nil
        // A rest only exists between exercises: nil for an ordinary reminder,
        // for none, and for a single exercise (the field is hidden then, so a
        // stale value must not be saved behind the user's back).
        reminder.restBetweenExercisesSeconds =
            (reminder.exercises?.count ?? 0) > 1 && restBetweenExercisesSeconds > 0
                ? min(restBetweenExercisesSeconds, Exercise.restRange.upperBound)
                : nil
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
