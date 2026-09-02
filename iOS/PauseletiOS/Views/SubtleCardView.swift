import SwiftUI
import ReminderCore

/// The quiet in-app card for `.subtle` reminders while the app is frontmost —
/// the ported macOS corner hint. It must register without hijacking
/// attention: no sound, small, and it disappears on its own.
struct SubtleCardView: View {
    let item: AppModel.SubtleCardItem
    /// `true` when the user tapped the checkmark; `false` on swipe-dismiss.
    let onAcknowledge: (Bool) -> Void

    private var reminder: Reminder { item.reminder }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: reminder.symbolName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color(red: 0.36, green: 0.72, blue: 0.67))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                if !reminder.message.isEmpty {
                    Text(reminder.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Button {
                onAcknowledge(true)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(red: 0.30, green: 0.68, blue: 0.62))
                    // A generous hit area: the glyph alone is a small target.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark as done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < 0 {
                    onAcknowledge(false)
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtleCard")
    }
}
