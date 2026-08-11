// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Reminder",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ReminderCore", targets: ["ReminderCore"]),
        .executable(name: "ReminderApp", targets: ["ReminderApp"]),
    ],
    targets: [
        .target(
            name: "ReminderCore",
            path: "Sources/ReminderCore"
        ),
        .executableTarget(
            name: "ReminderApp",
            dependencies: ["ReminderCore"],
            path: "Sources/ReminderApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReminderCoreTests",
            dependencies: ["ReminderCore"],
            path: "Tests/ReminderCoreTests"
        ),
    ]
)
