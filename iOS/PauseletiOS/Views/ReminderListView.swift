import SwiftUI
import ReminderCore
import ReminderUI

/// The everyday surface: see what is coming, mark something done, pause for a
/// while. Ports the macOS menu-bar popover's structure into a navigation list.
struct ReminderListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var engine: ReminderEngine

    @State private var editing: Reminder?
    @State private var isCreating = false
    @State private var pendingDeletion: Reminder?

    var body: some View {
        // The list itself only re-renders when engine state changes; the
        // per-second clock is scoped to the header and each row's countdown.
        List {
            Section {
                NextUpHeader()
            }
            Section {
                if engine.reminders.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedReminders(), id: \.reminder.id) { entry in
                        ReminderRow(reminder: entry.reminder, next: entry.next)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = entry.reminder }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if entry.reminder.isEnabled {
                                Button {
                                    engine.complete(id: entry.reminder.id)
                                    model.setNeedsReschedule()
                                } label: {
                                    Label("Done", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDeletion = entry.reminder
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editing = entry.reminder
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button("Edit") { editing = entry.reminder }
                            Button("Duplicate") { duplicate(entry.reminder) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                pendingDeletion = entry.reminder
                            }
                        }
                    }
                }
            } footer: {
                if !engine.reminders.isEmpty {
                    Text("\(engine.reminders.filter(\.isEnabled).count) active")
                }
            }
        }
        .navigationTitle("Pauselet")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PauseMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreating = true
                } label: {
                    Label("Add Reminder", systemImage: "plus")
                }
                .accessibilityIdentifier("addReminder")
            }
        }
        .sheet(item: $editing) { reminder in
            ReminderEditorView(reminder: reminder) { updated in
                engine.update(updated)
                model.setNeedsReschedule()
            }
        }
        .sheet(isPresented: $isCreating) {
            ReminderEditorView(reminder: nil) { created in
                engine.add(created)
                model.setNeedsReschedule()
            }
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
                if let pendingDeletion {
                    engine.delete(id: pendingDeletion.id)
                    model.setNeedsReschedule()
                }
                pendingDeletion = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    /// Ordered by the pending fire — the moment each is next obliged to fire,
    /// which does not depend on "now", so the order (and the sort) only
    /// changes when the engine's state does.
    private func sortedReminders() -> [(reminder: Reminder, next: Date?)] {
        engine.reminders
            .map { ($0, Scheduler.pendingFireDate(for: $0)) }
            .sorted { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.0.title < rhs.0.title
                }
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
        model.setNeedsReschedule()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No reminders yet")
                .font(.headline)
            Text("Tap + to add one.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

/// "Next up" with a live countdown, or the pause state — the popover header.
private struct NextUpHeader: View {
    @EnvironmentObject private var engine: ReminderEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let isPaused = Scheduler.isPaused(settings: engine.settings, now: now)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isPaused ? "Paused" : "Next up")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isPaused {
                    Text(pausedDescription(now: now))
                        .font(.system(.headline, design: .rounded).weight(.medium))
                } else if let next = engine.nextUp {
                    HStack(spacing: 7) {
                        Image(systemName: next.reminder.symbolName)
                            .foregroundStyle(.tint)
                        Text(next.reminder.title)
                            .font(.system(.headline, design: .rounded).weight(.medium))
                        Text("· \(Scheduler.countdownText(from: now, to: next.date))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Nothing scheduled")
                        .font(.system(.headline, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func pausedDescription(now: Date) -> String {
        guard let until = engine.settings.pausedUntil else { return "All reminders" }
        return "Resumes in \(Scheduler.countdownText(from: now, to: until))"
    }
}

/// Pause/resume controls: 30 m / 1 h / 2 h / indefinite, driving the existing
/// engine APIs.
private struct PauseMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var engine: ReminderEngine

    private var isPaused: Bool {
        Scheduler.isPaused(settings: engine.settings, now: Date())
    }

    var body: some View {
        Menu {
            if isPaused {
                Button {
                    engine.resume()
                    model.setNeedsReschedule()
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
            } else {
                Button("Pause for 30 minutes") { pause(minutes: 30) }
                Button("Pause for 1 hour") { pause(minutes: 60) }
                Button("Pause for 2 hours") { pause(minutes: 120) }
                Button("Pause until resumed") {
                    engine.setPaused(true)
                    model.setNeedsReschedule()
                }
            }
        } label: {
            Label(
                isPaused ? "Resume" : "Pause",
                systemImage: isPaused ? "play.circle.fill" : "pause.circle"
            )
        }
        .accessibilityIdentifier("pauseMenu")
    }

    private func pause(minutes: Int) {
        engine.pause(forMinutes: minutes)
        model.setNeedsReschedule()
    }
}

/// A single row: icon, title, priority dot + schedule summary, countdown, and
/// the enable switch. Only the row re-renders each second, for its countdown.
private struct ReminderRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var engine: ReminderEngine

    let reminder: Reminder
    let next: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func isOverdue(now: Date) -> Bool {
        guard let next, reminder.isEnabled,
              !Scheduler.isPaused(settings: engine.settings, now: now) else { return false }
        return next <= now
    }

    private func content(now: Date) -> some View {
        let isOverdue = isOverdue(now: now)
        return HStack(spacing: 12) {
            Image(systemName: reminder.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(
                    reminder.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(reminder.isEnabled ? .primary : .secondary)

                HStack(spacing: 6) {
                    PriorityDot(priority: reminder.priority)
                    Text(reminder.scheduleLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if reminder.isEnabled, let next {
                Text(isOverdue ? "due" : Scheduler.countdownText(from: now, to: next))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(isOverdue ? Color.orange : .secondary)
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { reminder.isEnabled },
                    set: { enabled in
                        engine.setEnabled(enabled, for: reminder.id)
                        model.setNeedsReschedule()
                    }
                )
            )
            .labelsHidden()
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(now: now, isOverdue: isOverdue))
        .accessibilityHint("Double tap to edit")
    }

    private func accessibilityDescription(now: Date, isOverdue: Bool) -> String {
        var parts = [
            reminder.title,
            reminder.priority.displayName,
            reminder.scheduleLine,
        ]
        if !reminder.isEnabled {
            parts.append("off")
        } else if let next {
            parts.append(
                isOverdue ? "due now" : "in \(Scheduler.countdownText(from: now, to: next))"
            )
        }
        return parts.joined(separator: ", ")
    }
}
