import SwiftUI
import AppKit
import ReminderCore

/// What the app is, who made it, and where to find more.
///
/// The description mirrors the README's opening, deliberately: someone who
/// finds the app through the repository and someone who opens Settings should
/// be told the same thing about what it is and why it exists.
struct AboutTab: View {

    /// Read from the bundle rather than hard-coded, so a version bump in the
    /// build script cannot leave a stale number on screen here.
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "—"
    }

    private static let email = "support@myaccessibility.ai"

    private struct Link: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String
        let url: URL
    }

    private static let links: [Link] = [
        Link(
            label: "myaccessibility.ai",
            symbol: "globe",
            url: URL(string: "https://myaccessibility.ai")!
        ),
        Link(
            label: "YouTube",
            symbol: "play.rectangle",
            url: URL(string: "https://www.youtube.com/@myaccessibility")!
        ),
        Link(
            label: "Instagram",
            symbol: "camera",
            url: URL(string: "https://www.instagram.com/myaccessibility")!
        ),
        Link(
            label: "LinkedIn",
            symbol: "person.crop.square",
            url: URL(string: "https://www.linkedin.com/in/chris-venter/")!
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider().padding(.vertical, 18)

                description

                Divider().padding(.vertical, 18)

                Text("More from MyAccessibility.ai")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.bottom, 8)

                Text(
                    "A nonprofit making free accessibility software, 3D print "
                    + "files and resources for people with spinal cord injuries "
                    + "and disabilities."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

                linkRow

                Divider().padding(.vertical, 18)

                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            // The real app icon, so this looks like the app rather than a
            // generic panel. Falls back to a symbol if the resource is missing.
            Group {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "clock.badge.checkmark")
                        .resizable()
                }
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text("Pauselet")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Version \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Recurring reminders for macOS, where you choose how "
                     + "loudly each one interrupts you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "It was built for a wheelchair user who needs regular pressure "
                + "relief, so the central idea is that a medically important "
                + "prompt and a nice-to-have nudge should not feel the same. It "
                + "works just as well for anyone who wants to drink water, "
                + "stretch, take medication, or call their mum every Sunday."
            )

            Text(
                "Everything is stored locally. There is no account, no sync, "
                + "and no network code in the app at all — the optional Spotify "
                + "playback drives the Spotify app on your own Mac through "
                + "AppleScript, not through any web service."
            )
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var linkRow: some View {
        // Wraps, so a narrow window does not clip the last link.
        FlowLayout(spacing: 8) {
            ForEach(Self.links) { link in
                Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: link.symbol)
                        Text(link.label)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help(link.url.absoluteString)
                .accessibilityHint("Opens \(link.url.absoluteString) in your browser")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Questions or feedback:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(Self.email) {
                    if let url = URL(string: "mailto:\(Self.email)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            Text("Free and open source, under the MIT licence.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Lays views out in a row, wrapping to the next line when they run out of
/// width.
///
/// `HStack` would clip or squeeze the links when the window is narrow, and a
/// `LazyVGrid` would force them into columns of equal width regardless of how
/// long each label is.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
