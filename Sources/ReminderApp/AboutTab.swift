import SwiftUI
import AppKit
import ReminderCore
import ReminderUI

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Divider().padding(.vertical, 18)

                description

                Divider().padding(.vertical, 18)

                Text(AboutContent.moreHeading)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.bottom, 8)

                Text(AboutContent.nonprofit)
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
            Text(AboutContent.origin)

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
            ForEach(AboutContent.links) { link in
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
                Text(AboutContent.feedbackPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button(AboutContent.email) {
                    if let url = URL(string: "mailto:\(AboutContent.email)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            Text(AboutContent.licence)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
