import SwiftUI
import ReminderCore

/// Adherence and recent events over 24 h / 7 d / 30 d windows — the ported
/// macOS History tab, with the §3.3 honesty caveat in copy: iOS delivers
/// reminders while the app is closed, so history records what the app could
/// witness rather than guessing at the rest.
struct HistoryView: View {
    @EnvironmentObject private var engine: ReminderEngine
    @State private var windowDays = 7
    @State private var isConfirmingClear = false

    private var since: Date {
        Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
    }

    private var recentEvents: [ReminderEvent] {
        engine.events.filter { $0.date >= since }.sorted { $0.date > $1.date }
    }

    var body: some View {
        // Computed once per body: the filter and sort run over up to 2000
        // events, and adherence is a single pass rather than one per reminder.
        let events = recentEvents
        let adherence = engine.adherence(since: since)
        List {
            Section {
                Picker("Window", selection: $windowDays) {
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if events.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("No activity in this period")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Adherence") {
                    ForEach(engine.reminders) { reminder in
                        if let value = adherence[reminder.id] {
                            AdherenceRow(reminder: reminder, adherence: value)
                        }
                    }
                }

                Section {
                    ForEach(events.prefix(200)) { event in
                        HStack {
                            Text(event.reminderTitle)
                                .font(.subheadline)
                            Spacer()
                            Text(event.outcome.rawValue.capitalized)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(event.date, style: .relative)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 80, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    honestyFootnote
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(engine.events.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { engine.clearHistory() }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var honestyFootnote: some View {
        Text(
            "While Pauselet is closed, iOS delivers its reminders. What you do "
            + "on the lock screen isn't always visible to the app, so history "
            + "records what it could witness — and marks anything it couldn't "
            + "as missed, rather than guessing."
        )
        .font(.caption)
    }
}

struct AdherenceRow: View {
    let reminder: Reminder
    let adherence: Double

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reminder.symbolName)
                .frame(width: 22)
                .foregroundStyle(.tint)
            Text(reminder.title)
                .font(.subheadline)
            Spacer()
            ProgressView(value: adherence)
                .frame(width: 90)
            Text("\(Int(adherence * 100))%")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(reminder.title), \(Int(adherence * 100)) percent completed"
        )
    }
}
