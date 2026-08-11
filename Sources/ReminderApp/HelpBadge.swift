import SwiftUI

/// A circled "i" that explains a setting when clicked.
///
/// A tooltip alone is not good enough here: it needs a hover, which is awkward
/// or impossible with head-pointer, switch, and other assistive input. This is a
/// real button, so it works with a click, the keyboard, and VoiceOver — and the
/// explanation stays on screen until dismissed rather than vanishing when the
/// pointer drifts.
struct HelpBadge: View {
    let text: String

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                // A generous hit area: the glyph alone is a small target.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(text)
        .accessibilityLabel("Help")
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 250, alignment: .leading)
                .padding(12)
        }
    }
}

/// A settings row with its label, an explanation badge, and a trailing control.
///
/// Keeps the label and help icon adjacent so the badge clearly belongs to that
/// setting rather than floating between two of them.
struct HelpRow<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpBadge(text: help)
            Spacer(minLength: 8)
            content
        }
    }
}
