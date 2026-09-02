import SwiftUI

/// A circled "i" that explains a setting when clicked or tapped.
///
/// A tooltip alone is not good enough here: it needs a hover, which is awkward
/// or impossible with head-pointer, switch, and other assistive input. This is a
/// real button, so it works with a click, a tap, the keyboard, and VoiceOver —
/// and the explanation stays on screen until dismissed rather than vanishing
/// when the pointer drifts.
///
/// One implementation for both apps, so the accessibility behaviour cannot
/// quietly diverge. The Mac adds hover feedback and a tooltip for pointer
/// users; iOS uses a larger touch target and keeps the popover a popover on
/// compact widths instead of letting it become a sheet.
public struct HelpBadge: View {
    public let text: String

    @State private var isPresented = false
    @State private var isHovering = false

    public init(text: String) {
        self.text = text
    }

    #if os(macOS)
    private let glyphSize: CGFloat = 13
    private let hitSize: CGFloat = 22
    private let bodySize: CGFloat = 12
    #else
    private let glyphSize: CGFloat = 15
    private let hitSize: CGFloat = 30
    private let bodySize: CGFloat = 14
    #endif

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: glyphSize))
                .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                // A generous hit area: the glyph alone is a small target.
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Help")
        .accessibilityHint(text)
        .modifier(PlatformHelp(text: text))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            explanation
        }
    }

    @ViewBuilder
    private var explanation: some View {
        #if os(macOS)
        Text(text)
            .font(.system(size: bodySize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 250, alignment: .leading)
            .padding(12)
        #else
        Text(text)
            .font(.system(size: bodySize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(idealWidth: 280, maxWidth: 300, alignment: .leading)
            .padding(14)
            .presentationCompactAdaptation(.popover)
        #endif
    }
}

/// The pointer tooltip, which only exists on the Mac.
private struct PlatformHelp: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content.help(text)
        #else
        content
        #endif
    }
}

/// A settings row with its label, an explanation badge, and a trailing control.
///
/// Keeps the label and help icon adjacent so the badge clearly belongs to that
/// setting rather than floating between two of them.
public struct HelpRow<Content: View>: View {
    public let title: String
    public let help: String
    @ViewBuilder public var content: Content

    public init(title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text(title)
            HelpBadge(text: help)
            Spacer(minLength: 8)
            content
        }
    }
}
