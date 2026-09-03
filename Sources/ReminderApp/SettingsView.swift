import SwiftUI
import ReminderCore
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
            ReminderEditor(reminder: reminder) { updated in
                engine.update(updated)
            }
            .environmentObject(engine)
            .environmentObject(music)
        }
        .sheet(isPresented: $isCreating) {
            ReminderEditor(reminder: nil) { created in
                engine.add(created)
            }
            .environmentObject(engine)
            .environmentObject(music)
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
                .foregroundStyle(reminder.isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

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
                            hour: binding(\.quietHours.startHour),
                            minute: binding(\.quietHours.startMinute)
                        )
                        Text("to")
                            // Full contrast, matching "From" — it is a label in
                            // the same sentence, not secondary chrome.
                            //
                            // Nudged onto the digits' centre line. TimeField
                            // carries an internal correction for the stepper's
                            // phantom label, which moves the row's centre away
                            // from where a plain label lands; this offset is
                            // measured from a rendered screenshot to match.
                            .offset(y: TimeComponentField.separatorCorrection)
                            .padding(.horizontal, 10)
                        TimeField(
                            hour: binding(\.quietHours.endHour),
                            minute: binding(\.quietHours.endMinute)
                        )
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
                Text("All reminders and history stay on this Mac.")
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

/// Two steppers for an hour and minute, kept compact enough to sit inline.
struct TimeField: View {
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        HStack(spacing: 3) {
            TimeComponentField(value: $hour, range: 0...23, label: "Hour")
            Text(":")
                .foregroundStyle(.secondary)
            TimeComponentField(value: $minute, range: 0...59, label: "Minute")
        }
    }
}

/// One editable two-digit component of a time, with a stepper beside it.
///
/// Typing matters here: stepping from 00 to 59 a minute at a time is no way to
/// set a time, and it is worse with assistive input. The field accepts a typed
/// value and clamps it, while the stepper stays for fine adjustment.
struct TimeComponentField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    /// Corrects the stepper's built-in label spacing so its arrows sit level
    /// with the digits beside them.
    private static let stepperVerticalCorrection: CGFloat = 11

    /// Shifts a plain label sitting beside these controls onto their centre
    /// line. Measured from rendered screenshots: it matches the correction the
    /// stepper itself needs, which is the same phantom-label space.
    static let separatorCorrection: CGFloat = 11

    var body: some View {
        // A Stepper wrapping an EmptyView still reserves space for that label
        // above its arrows, which pushed it up off the digits. Giving the
        // stepper a fixed size and centring both in a shared-height row is what
        // actually lines them up.
        HStack(alignment: .center, spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(width: 42)
                .focused($isFocused)
                .accessibilityLabel(label)
                .onSubmit(commit)
                .onChange(of: isFocused) { focused in
                    // Commit when focus leaves, so a typed value is not lost by
                    // clicking elsewhere instead of pressing Return.
                    if !focused { commit() }
                }

            // A labelless Stepper still reserves the space its label would
            // have taken above the arrows, so it renders ~11pt higher than the
            // field beside it. Measured against a screenshot and corrected
            // here, since no alignment guide reaches inside the control.
            Stepper("", value: $value, in: range)
                .labelsHidden()
                .fixedSize()
                .offset(y: Self.stepperVerticalCorrection)
                .accessibilityLabel(label)
        }
        .onAppear { text = formatted }
        .onChange(of: value) { _ in
            // Keep the text in step when the stepper drives the value.
            if !isFocused { text = formatted }
        }
    }

    private var formatted: String { String(format: "%02d", value) }

    /// Applies whatever was typed, ignoring anything that is not a number and
    /// clamping to the valid range rather than rejecting it outright.
    private func commit() {
        let digits = text.filter(\.isNumber)
        if let typed = Int(digits) {
            value = min(max(typed, range.lowerBound), range.upperBound)
        }
        text = formatted
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
                                Text(event.date, style: .relative)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 96, alignment: .trailing)
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
                .foregroundStyle(.tint)
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
