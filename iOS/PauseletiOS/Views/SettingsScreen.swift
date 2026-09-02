import SwiftUI
import UserNotifications
import ReminderCore
import ReminderUI

/// Global preferences: quiet hours, snooze, sounds, permissions, and where
/// the data lives. macOS-only items (launch at login, menu bar, music) have
/// no meaning here and are gone.
struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var engine: ReminderEngine

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var alarmsAuthorized = false

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
                    DatePicker(
                        "From",
                        selection: timeBinding(
                            hour: \.quietHours.startHour, minute: \.quietHours.startMinute
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "To",
                        selection: timeBinding(
                            hour: \.quietHours.endHour, minute: \.quietHours.endMinute
                        ),
                        displayedComponents: .hourAndMinute
                    )

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
                    title: "Subtle cards stay for "
                        + "\(engine.settings.subtleDisplaySeconds)s",
                    help: "How long a Subtle card stays on screen inside the "
                        + "app before it fades away. Individual reminders can "
                        + "override this in their own settings."
                ) {
                    Stepper("", value: binding(\.subtleDisplaySeconds), in: 2...60)
                        .labelsHidden()
                }

                HelpRow(
                    title: "Play sounds",
                    help: "Plays a sound for Important reminders, and for "
                        + "Critical reminders while Pauselet is open. Subtle "
                        + "and Normal reminders are always silent. Critical "
                        + "alarms on the Lock Screen always sound, so they can "
                        + "reach you."
                ) {
                    Toggle("", isOn: binding(\.soundEnabled)).labelsHidden()
                }
            }

            Section("Permissions") {
                LabeledContent("Notifications") {
                    Text(notificationStatusText)
                        .foregroundStyle(notificationStatusOK ? Color.secondary : Color.orange)
                }
                LabeledContent("Alarms (critical tier)") {
                    Text(alarmsAuthorized ? "Allowed" : "Not allowed")
                        .foregroundStyle(alarmsAuthorized ? Color.secondary : Color.orange)
                }
                if !notificationStatusOK || !alarmsAuthorized {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Text(
                        "Without notifications, reminders cannot reach you when "
                        + "Pauselet is closed. Without alarms, Critical "
                        + "reminders fall back to time-sensitive notifications "
                        + "— they will not pierce Silent mode."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                LabeledContent("Stored at") {
                    Text(storageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                Text("All reminders and history stay on this device. There is "
                     + "no account, no sync, and no network code in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await refreshPermissionStatus() }
        .onChange(of: model.isActive) { _, active in
            // Coming back from the Settings app: re-read what the user chose.
            if active {
                Task { await refreshPermissionStatus() }
            }
        }
    }

    private func refreshPermissionStatus() async {
        notificationStatus = await model.notifications.authorizationStatus
        alarmsAuthorized = model.alarms.isAuthorized
    }

    private var notificationStatusOK: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var storageDescription: String {
        (try? FileDataStore.defaultFileURL().path) ?? "App container"
    }

    /// Writes straight through to the engine so changes persist immediately —
    /// and re-schedules, since quiet hours and sounds shape what the system
    /// has been told to deliver.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<ReminderCore.Settings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { engine.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = engine.settings
                settings[keyPath: keyPath] = newValue
                engine.updateSettings(settings)
                model.setNeedsReschedule()
            }
        )
    }

    private func timeBinding(
        hour hourPath: WritableKeyPath<ReminderCore.Settings, Int>,
        minute minutePath: WritableKeyPath<ReminderCore.Settings, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: engine.settings[keyPath: hourPath],
                    minute: engine.settings[keyPath: minutePath],
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents(
                    [.hour, .minute], from: newValue
                )
                var settings = engine.settings
                settings[keyPath: hourPath] = comps.hour ?? 0
                settings[keyPath: minutePath] = comps.minute ?? 0
                engine.updateSettings(settings)
                model.setNeedsReschedule()
            }
        )
    }
}
