import SwiftUI
import ReminderCore
import ReminderAI
import ReminderUI

/// The main window: manage reminders, global preferences, and history.
struct SettingsView: View {
    @EnvironmentObject private var engine: ReminderEngine
    @State private var selection: Tab = .reminders

    enum Tab: String, CaseIterable, Identifiable {
        case reminders, preferences, history, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .reminders: return "Reminders"
            case .preferences: return "Preferences"
            case .history: return "History"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .reminders: return "bell.badge"
            case .preferences: return "gearshape"
            case .history: return "chart.bar"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                Group {
                    switch tab {
                    case .reminders: RemindersTab()
                    case .preferences: PreferencesTab()
                    case .history: HistoryTab()
                    case .about: AboutTab()
                    }
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
        .padding(.top, 6)
        .frame(minWidth: 640, minHeight: 460)
    }
}

// MARK: - Reminders

struct RemindersTab: View {
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var ai: AIImportController
    @State private var editing: Reminder?
    @State private var isCreating = false
    @State private var pendingDeletion: Reminder?

    var body: some View {
        VStack(spacing: 0) {
            if engine.reminders.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(engine.reminders) { reminder in
                        ReminderEditRow(reminder: reminder)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = reminder }
                            .contextMenu {
                                Button("Edit…") { editing = reminder }
                                Button("Duplicate") { duplicate(reminder) }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    pendingDeletion = reminder
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    isCreating = true
                } label: {
                    Label("Add Reminder", systemImage: "plus")
                }

                Spacer()

                Text("\(engine.reminders.filter(\.isEnabled).count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        // A sheet gets a fresh environment, so the objects the editor reads are
        // passed in explicitly rather than inherited from this view.
        .sheet(item: $editing) { reminder in
            ReminderEditor(reminder: reminder, settings: engine.settings) { updated in
                // Keeps whatever the engine stamped while the sheet was open.
                engine.applyEdits(updated)
            }
            .environmentObject(engine)
            .environmentObject(music)
            .environmentObject(ai)
        }
        .sheet(isPresented: $isCreating) {
            ReminderEditor(reminder: nil, settings: engine.settings) { created in
                engine.add(created)
            }
            .environmentObject(engine)
            .environmentObject(music)
            .environmentObject(ai)
        }
        // A confirmation step, because deleting a reminder silently loses its
        // history as well as the reminder itself.
        .alert(
            "Delete \(pendingDeletion?.title ?? "reminder")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let pendingDeletion { engine.delete(id: pendingDeletion.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func duplicate(_ reminder: Reminder) {
        var copy = reminder
        copy.id = UUID()
        copy.title = "\(reminder.title) copy"
        copy.lastFiredAt = nil
        copy.lastAcknowledgedAt = nil
        copy.snoozedUntil = nil
        engine.add(copy)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("No reminders")
                .font(.headline)
            Text("Add a reminder to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReminderEditRow: View {
    @EnvironmentObject private var engine: ReminderEngine
    let reminder: Reminder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reminder.symbolName)
                .font(.system(size: 17))
                .frame(width: 26)
                .foregroundStyle(reminder.isEnabled ? AnyShapeStyle(PriorityDot.color(for: reminder.priority)) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(reminder.schedule.summary)
                    Text("·")
                    HStack(spacing: 4) {
                        PriorityDot(priority: reminder.priority)
                        Text(reminder.priority.displayName)
                    }
                    if let exercises = reminder.exerciseSummary {
                        Text("·")
                        Text(exercises)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { reminder.isEnabled },
                    set: { engine.setEnabled($0, for: reminder.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Preferences

struct PreferencesTab: View {
    @EnvironmentObject private var engine: ReminderEngine

    var body: some View {
        Form {
            Section("Quiet Hours") {
                HelpRow(
                    title: "Enable quiet hours",
                    help: "Silences reminders during a window you choose, such "
                        + "as overnight. Fixed-time reminders whose moment "
                        + "falls inside the window are skipped; repeating "
                        + "interval reminders resume once it ends."
                ) {
                    Toggle("", isOn: binding(\.quietHours.isEnabled))
                        .labelsHidden()
                }

                if engine.settings.quietHours.isEnabled {
                    HStack(alignment: .center, spacing: 4) {
                        Text("From")
                        HelpBadge(
                            text: "The quiet window. It may run past midnight — "
                                + "22:00 to 07:00 covers the night."
                        )
                        Spacer(minLength: 8)
                        TimeField(
                            "Quiet hours start",
                            hour: binding(\.quietHours.startHour),
                            minute: binding(\.quietHours.startMinute)
                        )
                        .labelsHidden()
                        Text("to")
                            // Full contrast, matching "From" — it is a label in
                            // the same sentence, not secondary chrome.
                            .padding(.horizontal, 10)
                        TimeField(
                            "Quiet hours end",
                            hour: binding(\.quietHours.endHour),
                            minute: binding(\.quietHours.endMinute)
                        )
                        .labelsHidden()
                    }

                    HelpRow(
                        title: "Still show critical reminders",
                        help: "Lets Critical reminders through during quiet "
                            + "hours. Keep this on if a reminder matters "
                            + "medically — pressure relief still matters at "
                            + "3am. Every other tier stays silent."
                    ) {
                        Toggle("", isOn: binding(\.quietHours.allowsCritical))
                            .labelsHidden()
                    }
                }
            }

            Section("Behaviour") {
                HelpRow(
                    title: "Snooze length: \(engine.settings.snoozeMinutes) min",
                    help: "How long Snooze puts a reminder off for. A snooze "
                        + "always brings the reminder back, even if its next "
                        + "scheduled time is further away."
                ) {
                    Stepper("", value: binding(\.snoozeMinutes), in: 1...120)
                        .labelsHidden()
                }

                HelpRow(
                    title: "Subtle reminders stay for "
                        + "\(engine.settings.subtleDisplaySeconds)s",
                    help: "How long a Subtle card stays on screen before it "
                        + "fades away. Individual reminders can override this "
                        + "in their own settings. Normal and Important use "
                        + "macOS notifications, whose timing macOS controls."
                ) {
                    Stepper("", value: binding(\.subtleDisplaySeconds), in: 2...60)
                        .labelsHidden()
                }

                HelpRow(
                    title: "Play sounds",
                    help: "Plays a sound for Important and Critical reminders. "
                        + "Subtle reminders are always silent."
                ) {
                    Toggle("", isOn: binding(\.soundEnabled)).labelsHidden()
                }

                HelpRow(
                    title: "Show countdown in menu bar",
                    help: "Shows the time until your next reminder beside the "
                        + "menu bar icon. Turn off for just the icon."
                ) {
                    Toggle("", isOn: binding(\.showsNextReminderInMenuBar))
                        .labelsHidden()
                }
            }

            MusicSettingsSection()

            VoiceCoachSection()

            AIImportSection()

            Section("Startup") {
                HelpRow(
                    title: "Launch at login",
                    help: "Starts Reminder automatically when you log in. Worth "
                        + "having on: a reminder app you have to remember to "
                        + "start is not much of a reminder app."
                ) {
                    Toggle("", isOn: launchAtLoginBinding).labelsHidden()
                }
            }

            Section("Data") {
                LabeledContent("Stored at") {
                    Text(storageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(
                    "All reminders and history stay on this Mac. Only exercise text you "
                        + "choose to interpret with AI is sent to OpenAI."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: syncLaunchAtLogin)
    }

    /// The user can flip this in System Settings › Login Items behind the
    /// app's back; show the registration's real state, not the last thing
    /// saved here. Skipped when running unbundled, where no registration
    /// exists to compare against.
    private func syncLaunchAtLogin() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let actual = LaunchAtLogin.isEnabled
        if engine.settings.launchAtLogin != actual {
            var settings = engine.settings
            settings.launchAtLogin = actual
            engine.updateSettings(settings)
        }
    }

    private var storageDescription: String {
        (try? FileDataStore.defaultFileURL().path) ?? "Application Support/Reminder"
    }

    /// Writes straight through to the engine so changes persist immediately.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<ReminderCore.Settings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { engine.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = engine.settings
                settings[keyPath: keyPath] = newValue
                engine.updateSettings(settings)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { engine.settings.launchAtLogin },
            set: { newValue in
                var settings = engine.settings
                settings.launchAtLogin = newValue
                engine.updateSettings(settings)
                LaunchAtLogin.set(enabled: newValue)
            }
        )
    }
}

/// An hour and minute, edited with the system's own time control: a field
/// showing `07:25` with a stepper beside it.
///
/// This used to be two hand-built text fields, each with a SwiftUI `Stepper`.
/// A labelless `Stepper` still reserves space for its label, and the fixed
/// offsets that hid that space were measured on one Mac: on another, with
/// different control metrics, the colon rode high, the rows gained a gap, and
/// a field jumped while being typed in. A stepper click also left a focused
/// field showing its old number — and clicking away then wrote that stale
/// number back. One native control has none of these problems: the colon is
/// part of it, its layout box is its real size, and typing and stepping edit
/// the same value. Each part (hour, minute) can be typed into directly, and
/// the arrow keys and stepper adjust whichever part is selected.
///
/// Shows `title` as the row label in a form; add `.labelsHidden()` to place it
/// inline in a sentence, where the title is still read by VoiceOver.
struct TimeField: View {
    let title: String
    @Binding var hour: Int
    @Binding var minute: Int

    init(_ title: String, hour: Binding<Int>, minute: Binding<Int>) {
        self.title = title
        _hour = hour
        _minute = minute
    }

    var body: some View {
        // The label sits in a `LabeledContent` rather than on the picker: a
        // form lays out a labelled picker itself and stretches the field
        // across to the label, which reads as a text box, not a time.
        LabeledContent(title) {
            DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .fixedSize()
                // 24-hour, to read the same as the schedule summary beneath
                // it ("Every 5 min, 08:25–22:00") and the other platforms.
                .environment(\.locale, Self.locale)
                .environment(\.calendar, Self.calendar)
                .environment(\.timeZone, Self.calendar.timeZone)
        }
    }

    /// The time as a moment on one fixed day in GMT, which has no daylight
    /// saving: every hour and minute exists exactly once, so no value can be
    /// skipped or doubled on the way through the control.
    private var date: Binding<Date> {
        Binding(
            get: { Self.date(hour: hour, minute: minute) },
            set: { newValue in
                let parts = Self.components(of: newValue)
                if parts.hour != hour { hour = parts.hour }
                if parts.minute != minute { minute = parts.minute }
            }
        )
    }

    static let locale = Locale(identifier: "en_GB")

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        calendar.locale = locale
        return calendar
    }()

    static func date(hour: Int, minute: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(hour * 3600 + minute * 60))
    }

    static func components(of date: Date) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - History

struct HistoryTab: View {
    @EnvironmentObject private var engine: ReminderEngine
    @State private var windowDays = 7

    private var since: Date {
        Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
    }

    private var recentEvents: [ReminderEvent] {
        engine.events.filter { $0.date >= since }.sorted { $0.date > $1.date }
    }

    var body: some View {
        // Redrawn once a minute, which is all the "when" column needs: a
        // record of what happened, not a stopwatch. (SwiftUI's live relative
        // text redraws every second, times up to 200 rows.)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Window", selection: $windowDays) {
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                Spacer()

                Button("Clear History") { engine.clearHistory() }
                    .disabled(engine.events.isEmpty)
            }
            .padding(12)

            Divider()

            if recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("No activity in this period")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Adherence") {
                        ForEach(engine.reminders) { reminder in
                            if let adherence = engine.adherence(
                                for: reminder.id, since: since
                            ) {
                                AdherenceRow(reminder: reminder, adherence: adherence)
                            }
                        }
                    }

                    Section("Recent") {
                        ForEach(recentEvents.prefix(200)) { event in
                            HStack {
                                Text(event.reminderTitle)
                                    .font(.system(size: 12))
                                Spacer()
                                Text(event.outcome.rawValue.capitalized)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(HistoryTime.label(for: event.date, now: now))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 96, alignment: .trailing)
                                    .help(HistoryTime.exact(event.date))
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct AdherenceRow: View {
    let reminder: Reminder
    let adherence: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reminder.symbolName)
                .frame(width: 20)
                .foregroundStyle(PriorityDot.color(for: reminder.priority))
            Text(reminder.title)
                .font(.system(size: 12))
            Spacer()
            ProgressView(value: adherence)
                .frame(width: 120)
            Text("\(Int(adherence * 100))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}
