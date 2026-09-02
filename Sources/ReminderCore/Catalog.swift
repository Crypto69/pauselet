import Foundation

/// The fixed choices the reminder editor offers, shared by every platform's
/// editor so the Mac, iOS, and Windows apps cannot quietly drift apart on
/// which icons, intervals, or day order the user is shown.
public enum EditorCatalog {

    /// SF Symbols relevant to health and routine reminders.
    public static let symbols: [String] = [
        "bell", "figure.seated.side", "arrow.up.and.down.circle", "drop.fill",
        "figure.flexibility", "figure.walk", "pills.fill", "heart.fill",
        "lungs.fill", "eye.fill", "hand.raised.fill", "fork.knife",
        "moon.fill", "sun.max.fill", "phone.fill", "book.fill",
        "cross.case.fill", "dumbbell.fill", "timer", "wind",
    ]

    /// Common intervals, in minutes, offered as presets before "Custom".
    public static let intervalPresets: [Int] = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]

    /// A weekday as the picker shows it.
    public struct Weekday: Equatable, Sendable {
        /// `Calendar` numbering: 1 = Sunday … 7 = Saturday.
        public let number: Int
        /// The one-letter button label.
        public let label: String
        /// The full name, for accessibility.
        public let name: String
    }

    /// Monday-first, the order the picker lays the buttons out in.
    public static let weekdays: [Weekday] = [
        Weekday(number: 2, label: "M", name: "Monday"),
        Weekday(number: 3, label: "T", name: "Tuesday"),
        Weekday(number: 4, label: "W", name: "Wednesday"),
        Weekday(number: 5, label: "T", name: "Thursday"),
        Weekday(number: 6, label: "F", name: "Friday"),
        Weekday(number: 7, label: "S", name: "Saturday"),
        Weekday(number: 1, label: "S", name: "Sunday"),
    ]
}

/// The About screen's shared copy and links. The description mirrors the
/// README's opening, deliberately: someone who finds the app through the
/// repository and someone who opens About should be told the same thing
/// about what it is and why it exists. Each platform adds one paragraph of
/// its own about how it keeps the user's data local.
public enum AboutContent {

    public static let email = "support@myaccessibility.ai"

    public struct Link: Identifiable, Equatable, Sendable {
        public var id: String { label }
        public let label: String
        public let symbol: String
        public let url: URL
    }

    public static let links: [Link] = [
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

    public static let origin =
        "It was built for a wheelchair user who needs regular pressure "
        + "relief, so the central idea is that a medically important "
        + "prompt and a nice-to-have nudge should not feel the same. It "
        + "works just as well for anyone who wants to drink water, "
        + "stretch, take medication, or call their mum every Sunday."

    public static let moreHeading = "More from MyAccessibility.ai"

    public static let nonprofit =
        "A nonprofit making free accessibility software, 3D print "
        + "files and resources for people with spinal cord injuries "
        + "and disabilities."

    public static let feedbackPrompt = "Questions or feedback:"

    public static let licence = "Free and open source, under the MIT licence."
}
