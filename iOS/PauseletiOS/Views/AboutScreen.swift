import SwiftUI
import ReminderCore
import ReminderUI

/// What the app is, who made it, and where to find more — the ported macOS
/// About tab. The description mirrors the README's opening, deliberately.
struct AboutScreen: View {

    /// Read from the bundle rather than hard-coded, so a version bump cannot
    /// leave a stale number on screen here.
    private var version: String {
        let short = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
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
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 8)

                Text(AboutContent.nonprofit)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

                linkRow

                Divider().padding(.vertical, 18)

                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("About")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            // The real app icon, so this looks like the app rather than a
            // generic panel. Falls back to a symbol if the resource is missing.
            Group {
                if let icon = UIImage(named: "AboutIcon") {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "clock.badge.checkmark")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.tint)
                }
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text("Pauselet")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Version \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Recurring reminders where you choose how loudly each "
                     + "one interrupts you.")
                    .font(.footnote)
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
                + "and no network code in the app at all. Critical reminders "
                + "use Apple's alarm system, so they can reach you even in "
                + "Silent mode — that permission is asked for once, and used "
                + "for nothing else."
            )
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var linkRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(AboutContent.links) { link in
                Link(destination: link.url) {
                    HStack(spacing: 5) {
                        Image(systemName: link.symbol)
                        Text(link.label)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens \(link.url.absoluteString) in your browser")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(AboutContent.feedbackPrompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let url = URL(string: "mailto:\(AboutContent.email)") {
                    Link(AboutContent.email, destination: url)
                        .font(.subheadline)
                }
            }

            Text(AboutContent.licence)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
