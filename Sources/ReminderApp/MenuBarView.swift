import SwiftUI
import ReminderCore
import ReminderUI

/// The popover shown when the menu bar icon is clicked.
///
/// This is the everyday surface: see what is coming, mark something done, pause
/// for a while. Editing lives in the settings window rather than here.
struct MenuBarView: View {
    @ObservedObject var engine: ReminderEngine
    @Environment(\.openReminderSettings) private var openSettings

    /// Drives the countdown text without the engine having to publish per second.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isPaused: Bool {
        Scheduler.isPaused(settings: engine.settings, now: now)
    }

    private var sortedReminders: [(reminder: Reminder, next: Date?)] {
        engine.reminders
            .map { ($0, Scheduler.nextFireDate(for: $0, now: now)) }
            .sorted { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.0.title < rhs.0.title
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 380)
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isPaused ? "Paused" : "Next up")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isPaused {
                    Text(pausedDescription)
                        .font(.system(size: 15, weight: .medium))
                } else if let next = engine.nextUp {
                    HStack(spacing: 6) {
                        Image(systemName: next.reminder.symbolName)
                            .foregroundStyle(.tint)
                        Text(next.reminder.title)
                            .font(.system(size: 15, weight: .medium))
                        Text("· \(Scheduler.countdownText(from: now, to: next.date))")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Nothing scheduled")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                if isPaused { engine.resume() } else { engine.setPaused(true) }
            } label: {
                Image(systemName: isPaused ? "play.circle.fill" : "pause.circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isPaused ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isPaused ? "Resume reminders" : "Pause reminders")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var pausedDescription: String {
        guard let until = engine.settings.pausedUntil else { return "All reminders" }
        return "Resumes in \(Scheduler.countdownText(from: now, to: until))"
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if engine.reminders.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedReminders, id: \.reminder.id) { entry in
                        ReminderRow(
                            reminder: entry.reminder,
                            next: entry.next,
                            now: now,
                            isPaused: isPaused,
                            onToggle: { engine.setEnabled($0, for: entry.reminder.id) },
                            onComplete: { engine.complete(id: entry.reminder.id) }
                        )
                        Divider().padding(.leading, 46)
                    }
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No reminders yet")
                .font(.system(size: 14, weight: .medium))
            Text("Add one in Settings to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A single row in the popover list.
struct ReminderRow: View {
    let reminder: Reminder
    let next: Date?
    let now: Date
    let isPaused: Bool
    let onToggle: (Bool) -> Void
    let onComplete: () -> Void

    @State private var isHovering = false

    private var isOverdue: Bool {
        guard let next, reminder.isEnabled, !isPaused else { return false }
        return next <= now
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reminder.symbolName)
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(reminder.isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(reminder.isEnabled ? .primary : .secondary)

                HStack(spacing: 5) {
                    PriorityDot(priority: reminder.priority)
                    Text(reminder.scheduleLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if reminder.isEnabled, let next {
                Text(isOverdue ? "due" : Scheduler.countdownText(from: now, to: next))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isOverdue ? Color.orange : .secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }

            // Completing from here is the fast path for "I already did that".
            if isHovering && reminder.isEnabled {
                Button(action: onComplete) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Mark as done now")
            }

            Toggle(
                "",
                isOn: Binding(get: { reminder.isEnabled }, set: onToggle)
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(isHovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { isHovering = $0 }
    }
}
