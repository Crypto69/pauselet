import Foundation
import AppIntents

/// The system alarm's "Open" button. Launches the app and presents the
/// full-screen acknowledgment view for the reminder that fired — the custom
/// experience the templated alarm alert cannot provide.
struct PauseletAlarmOpenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Reminder"
    static let description = IntentDescription("Opens the reminder in Pauselet.")
    static let openAppWhenRun: Bool = true
    static let isDiscoverable: Bool = false

    @Parameter(title: "Reminder ID")
    var reminderID: String

    init() {}

    init(reminderID: UUID) {
        self.reminderID = reminderID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: reminderID) {
            AppModel.shared.handleAlarmOpened(reminderID: id)
        }
        return .result()
    }
}

/// The system alarm's Stop button. Runs in the app's process without opening
/// UI, so "Done" tapped on the lock screen reaches the engine immediately —
/// the interval re-anchors now, not at the next launch.
///
/// The intent does not return until the next occurrence is armed: this may be
/// a background launch that is suspended the moment `perform` returns, and a
/// one-shot alarm (an interval reminder — the pressure-relief case) whose
/// follow-up was still pending would simply never be scheduled.
struct PauseletAlarmStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Reminder Done"
    static let description = IntentDescription("Marks the reminder as done in Pauselet.")
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = false

    @Parameter(title: "Reminder ID")
    var reminderID: String

    init() {}

    init(reminderID: UUID) {
        self.reminderID = reminderID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: reminderID) {
            await AppModel.shared.handleAlarmStopped(reminderID: id)
        }
        return .result()
    }
}
