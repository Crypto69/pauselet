import Foundation
import SwiftUI
import ReminderCore
#if canImport(AlarmKit)
import AlarmKit
import ActivityKit
#endif

/// Owns the critical tier's AlarmKit alarms: authorization, keeping the alarm
/// set mirroring the reminder set, observing fires while the app runs, and
/// reconciling fires that happened while it did not.
///
/// One alarm per critical reminder, keyed by the reminder's own UUID so an
/// alarm event maps straight back to its reminder.
@MainActor
final class CriticalAlarmController {

    weak var model: AppModel?
    private let engine: ReminderEngine

    /// What each scheduled alarm was scheduled *as*, persisted so a fire that
    /// happened while the app was dead can be reconciled at next launch.
    ///
    /// The spec is stored whole rather than as a cached next fire date: a
    /// relative (weekly) alarm repeats system-side without the app running,
    /// so the occurrence being acknowledged has to be computed from the rule
    /// at the time of the acknowledgment. `scheduledAt` bounds that: an
    /// occurrence from before the alarm existed never rang.
    struct RegistryEntry: Codable, Equatable {
        var spec: AlarmPlan.Spec
        var scheduledAt: Date
    }

    /// A fire an alarm is known to have produced.
    struct ExpectedFire: Equatable {
        let fireDate: Date
        let stampDate: Date
    }

    private var registry: [UUID: RegistryEntry] {
        didSet { persistRegistry() }
    }

    private static let registryKey = "pauselet.criticalAlarmRegistry.v2"

    private(set) var isAuthorized = false

    private var observationTask: Task<Void, Never>?
    /// Alarm IDs seen in the last update, to detect disappearances.
    private var lastKnownAlarmIDs: Set<UUID> = []

    init(engine: ReminderEngine) {
        self.engine = engine
        if let data = UserDefaults.standard.data(forKey: Self.registryKey),
           let decoded = try? JSONDecoder().decode([UUID: RegistryEntry].self, from: data) {
            registry = decoded
        } else {
            registry = [:]
        }
        #if canImport(AlarmKit)
        isAuthorized = AlarmManager.shared.authorizationState == .authorized
        #endif
    }

    private func persistRegistry() {
        if let data = try? JSONEncoder().encode(registry) {
            UserDefaults.standard.set(data, forKey: Self.registryKey)
        }
    }

    // MARK: - What an alarm has done

    /// The fire `reminderID`'s alarm produced most recently, at or before
    /// `now`, or `nil` if it has not fired since it was scheduled.
    func expectedFire(for reminderID: UUID, at now: Date = Date()) -> ExpectedFire? {
        guard let entry = registry[reminderID] else { return nil }
        return Self.expectedFire(for: entry, at: now)
    }

    nonisolated static func expectedFire(
        for entry: RegistryEntry, at now: Date, calendar: Calendar = .current
    ) -> ExpectedFire? {
        switch entry.spec.kind {
        case .fixed(let fireDate, let stampDate):
            guard fireDate <= now else { return nil }
            return ExpectedFire(fireDate: fireDate, stampDate: stampDate)
        case .relativeWeekly(let hour, let minute, let weekdays):
            guard let occurrence = AlarmPlan.latestOccurrence(
                hour: hour, minute: minute, weekdays: weekdays,
                atOrBefore: now, calendar: calendar
            ), occurrence > entry.scheduledAt else { return nil }
            // A wall-clock alarm honours its slot: fire and stamp coincide.
            return ExpectedFire(fireDate: occurrence, stampDate: occurrence)
        }
    }

    /// Folds the alarm's most recent fire into the engine, if it has one.
    /// Idempotent, like `recordExternalFire` underneath it.
    @discardableResult
    private func recordFireIfDue(_ reminderID: UUID, now: Date = Date()) -> Bool {
        guard let fire = expectedFire(for: reminderID, at: now) else { return false }
        engine.recordExternalFire(
            id: reminderID, at: fire.stampDate, deliveredAt: fire.fireDate
        )
        return true
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        #if canImport(AlarmKit)
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            isAuthorized = true
        case .denied:
            isAuthorized = false
        case .notDetermined:
            let state = (try? await manager.requestAuthorization()) ?? .denied
            isAuthorized = state == .authorized
        @unknown default:
            isAuthorized = false
        }
        #endif
    }

    // MARK: - Observation (while the app runs)

    func startObserving() {
        #if canImport(AlarmKit)
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                await MainActor.run { [weak self] in
                    self?.handleUpdate(alarms)
                }
            }
        }
        #endif
    }

    #if canImport(AlarmKit)
    private func handleUpdate(_ alarms: [Alarm]) {
        let currentIDs = Set(alarms.map(\.id))

        // An alarm alerting while the app is frontmost: the in-app takeover
        // is the real experience; the system alert stands down.
        for alarm in alarms where alarm.state == .alerting {
            recordFireIfDue(alarm.id)
            model?.handleAlarmAlerting(reminderID: alarm.id)
        }

        // An alarm that vanished without our own cancel: the user stopped it
        // from the system surface, or a one-shot fired its last. The Stop
        // intent usually reported it already; reconcile covers the rest.
        let disappeared = lastKnownAlarmIDs.subtracting(currentIDs)
        lastKnownAlarmIDs = currentIDs
        guard !disappeared.isEmpty else { return }
        for id in disappeared {
            recordFireIfDue(id)
        }
        // Re-arm one-shot alarms (intervals, snoozes) from the new state. The
        // sync also drops registry entries for alarms that are gone.
        model?.setNeedsReschedule()
    }
    #endif

    // MARK: - Sync (schedule the future)

    /// Makes the system's alarm set mirror the critical reminders. Returns
    /// the IDs of the reminders AlarmKit is now carrying; the caller demotes
    /// every other critical reminder to a time-sensitive notification. That
    /// covers authorization being denied (nothing is carried) and a single
    /// `schedule` call failing (that one reminder is not), so a reminder can
    /// never end up with neither an alarm nor a notification.
    func sync(
        reminders: [Reminder], settings: ReminderCore.Settings, now: Date
    ) async -> Set<UUID> {
        #if canImport(AlarmKit)
        await requestAuthorizationIfNeeded()
        guard isAuthorized else { return [] }
        let manager = AlarmManager.shared

        let specs = AlarmPlan.specs(for: reminders, settings: settings, now: now)
        let wantedIDs = Set(specs.map(\.reminderID))
        let existing = (try? manager.alarms) ?? []
        let existingIDs = Set(existing.map(\.id))

        // Never touch an alarm that is alerting right now — cancelling it
        // would silently swallow the alert the user is being shown.
        let alerting = Set(existing.filter { $0.state == .alerting }.map(\.id))

        // Every mutation lands on a local copy; the registry (and its
        // UserDefaults write) is assigned once at the end.
        var registry = self.registry
        var carried: Set<UUID> = []

        for id in existingIDs where !wantedIDs.contains(id) && !alerting.contains(id) {
            try? manager.cancel(id: id)
            registry.removeValue(forKey: id)
        }
        for id in registry.keys where !wantedIDs.contains(id) && !existingIDs.contains(id) {
            registry.removeValue(forKey: id)
        }

        for spec in specs {
            let id = spec.reminderID
            if alerting.contains(id) {
                carried.insert(id)
                continue
            }
            // Re-scheduling is an upsert with the same ID; skip the round trip
            // when nothing about the alarm — dates or content — would change.
            if registry[id]?.spec == spec, existingIDs.contains(id) {
                carried.insert(id)
                continue
            }
            do {
                _ = try await manager.schedule(id: id, configuration: configuration(for: spec))
                registry[id] = RegistryEntry(spec: spec, scheduledAt: now)
                carried.insert(id)
            } catch {
                // Not carried: the caller schedules a notification instead. A
                // stale registry entry must not survive to report a fire that
                // this failed alarm can never produce.
                registry.removeValue(forKey: id)
            }
        }

        self.registry = registry
        lastKnownAlarmIDs = Set(((try? manager.alarms) ?? []).map(\.id))
        return carried
        #else
        return []
        #endif
    }

    // MARK: - Reconciliation (fires that happened while the app was away)

    /// Records fires whose moment passed while nothing was listening. The
    /// outcome (did they stop it? ignore it?) is unknowable here, so only the
    /// fire is recorded — `absorbBacklogFromDowntime` and history's "missed"
    /// marking handle the rest honestly. Registry entries are left in place:
    /// the next sync replaces or removes them.
    func reconcile(now: Date) async {
        #if canImport(AlarmKit)
        guard isAuthorized else { return }
        let fires = registry.compactMap { id, entry -> ReminderEngine.ExternalFire? in
            guard let fire = Self.expectedFire(for: entry, at: now) else { return nil }
            return ReminderEngine.ExternalFire(
                reminderID: id, stampDate: fire.stampDate, deliveredAt: fire.fireDate
            )
        }
        engine.recordExternalFires(fires)
        #endif
    }

    // MARK: - Direct control

    /// Silences the system alert for `reminderID` if it is currently sounding.
    func stopIfAlerting(_ reminderID: UUID) {
        #if canImport(AlarmKit)
        let existing = (try? AlarmManager.shared.alarms) ?? []
        guard let alarm = existing.first(where: { $0.id == reminderID }),
              alarm.state == .alerting else { return }
        try? AlarmManager.shared.stop(id: reminderID)
        #endif
    }

    // MARK: - Alarm construction

    #if canImport(AlarmKit)
    static let tint = Color(red: 0.42, green: 0.85, blue: 0.78)

    private func configuration(
        for spec: AlarmPlan.Spec
    ) -> AlarmManager.AlarmConfiguration<PauseletAlarmMetadata> {
        let openButton = AlarmButton(
            text: "Open",
            textColor: .white,
            systemImageName: "arrow.up.forward.app"
        )

        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: spec.title),
                secondaryButton: openButton,
                secondaryButtonBehavior: .custom
            )
        } else {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: spec.title),
                stopButton: AlarmButton(
                    text: "Done", textColor: .white, systemImageName: "checkmark"
                ),
                secondaryButton: openButton,
                secondaryButtonBehavior: .custom
            )
        }

        let attributes = AlarmAttributes<PauseletAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: PauseletAlarmMetadata(
                reminderID: spec.reminderID,
                symbolName: spec.symbolName,
                message: spec.message
            ),
            tintColor: Self.tint
        )

        let schedule: Alarm.Schedule
        switch spec.kind {
        case .fixed(let fireDate, _):
            schedule = .fixed(fireDate)
        case .relativeWeekly(let hour, let minute, let weekdays):
            schedule = .relative(
                Alarm.Schedule.Relative(
                    time: Alarm.Schedule.Relative.Time(hour: hour, minute: minute),
                    repeats: .weekly(Self.localeWeekdays(from: weekdays))
                )
            )
        }

        // A system alarm cannot be silent (AlarmKit offers no such option;
        // alarms exist to break through), and for the critical tier that is
        // the point: a pressure-relief prompt must reach the user. So the
        // "Play sounds" switch does not apply here — the settings help text
        // says so — and the alarm plays the reminder's sound, or the same
        // default the in-app takeover uses.
        return AlarmManager.AlarmConfiguration.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: PauseletAlarmStopIntent(reminderID: spec.reminderID),
            secondaryIntent: PauseletAlarmOpenIntent(reminderID: spec.reminderID),
            sound: .named("\(spec.soundName).caf")
        )
    }

    /// Calendar weekday numbering (1 = Sunday … 7 = Saturday) → Locale.Weekday.
    nonisolated static func localeWeekdays(from calendarWeekdays: Set<Int>) -> [Locale.Weekday] {
        let mapping: [Int: Locale.Weekday] = [
            1: .sunday, 2: .monday, 3: .tuesday, 4: .wednesday,
            5: .thursday, 6: .friday, 7: .saturday,
        ]
        return calendarWeekdays.sorted().compactMap { mapping[$0] }
    }
    #endif
}
