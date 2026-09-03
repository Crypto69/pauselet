// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reminder",
    // iOS 26 is the floor for the iOS app: AlarmKit *is* its critical tier.
    // The macOS app is unaffected; ReminderApp only builds for macOS.
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [
        .library(name: "ReminderCore", targets: ["ReminderCore"]),
        .library(name: "ReminderUI", targets: ["ReminderUI"]),
        .library(name: "ReminderAI", targets: ["ReminderAI"]),
        .executable(name: "ReminderApp", targets: ["ReminderApp"]),
    ],
    targets: [
        .target(
            name: "ReminderCore",
            path: "Sources/ReminderCore"
        ),
        // SwiftUI pieces that are identical on the Mac and on iOS — the
        // priority colours, the help badge and its accessibility behaviour,
        // the wrapping link row, the interval picker — so the two apps cannot
        // drift on them and a fix lands on both at once.
        .target(
            name: "ReminderUI",
            dependencies: ["ReminderCore"],
            path: "Sources/ReminderUI"
        ),
        // The one place with a network path out of the app, kept out of
        // ReminderCore so Store.swift's "nothing leaves this machine"
        // invariant stays literally true and this boundary stays auditable.
        // Also holds the platform secret store, so Security.framework never
        // reaches the shared core.
        .target(
            name: "ReminderAI",
            dependencies: ["ReminderCore"],
            path: "Sources/ReminderAI"
        ),
        .executableTarget(
            name: "ReminderApp",
            dependencies: ["ReminderCore", "ReminderUI", "ReminderAI"],
            path: "Sources/ReminderApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReminderCoreTests",
            dependencies: ["ReminderCore"],
            path: "Tests/ReminderCoreTests"
        ),
        .testTarget(
            name: "ReminderAITests",
            dependencies: ["ReminderAI"],
            path: "Tests/ReminderAITests"
        ),
    ],
    // The code predates Swift 6 strict concurrency; keep the language mode it
    // was written for rather than churning the shipping macOS app.
    swiftLanguageModes: [.v5]
)
