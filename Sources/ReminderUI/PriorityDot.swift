import SwiftUI
import ReminderCore

/// A small coloured dot conveying a reminder's priority at a glance.
///
/// The tier → colour mapping is the one both apps use everywhere a tier is
/// shown, so a critical reminder is the same red in a list row, the editor,
/// and the menu bar.
public struct PriorityDot: View {
    public let priority: Priority

    public init(priority: Priority) {
        self.priority = priority
    }

    /// Subtle's colour: the calm teal its corner card has always used, so the
    /// dot and the card agree without the card turning a disabled-looking grey.
    public static let subtleTeal = Color(red: 0.36, green: 0.72, blue: 0.67)

    /// The tier's colour, also used for the icon on the surfaces a reminder
    /// fires on, so a blue dot in the list means a blue icon on screen.
    public static func color(for priority: Priority) -> Color {
        switch priority {
        case .subtle: return subtleTeal
        case .normal: return Color.blue
        case .important: return Color.orange
        case .critical: return Color.red
        }
    }

    public var body: some View {
        Circle()
            .fill(Self.color(for: priority))
            .frame(width: 7, height: 7)
            .accessibilityLabel(priority.displayName)
    }
}
