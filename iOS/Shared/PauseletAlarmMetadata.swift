import Foundation
#if canImport(AlarmKit)
import AlarmKit

/// Rides along on every Pauselet alarm so the Live Activity (widget extension)
/// can render the reminder's own icon and message, and so an alarm can be
/// traced back to its reminder. Compiled into both the app and the widget.
struct PauseletAlarmMetadata: AlarmMetadata {
    let reminderID: UUID
    let symbolName: String
    let message: String

    init(reminderID: UUID, symbolName: String, message: String) {
        self.reminderID = reminderID
        self.symbolName = symbolName
        self.message = message
    }
}
#endif
