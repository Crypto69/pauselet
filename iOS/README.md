# Pauselet for iOS

The iOS port of Pauselet. The shared engine (`ReminderCore` at the repository
root) is consumed as a local Swift package; everything in this folder is
iOS-only. The macOS app and its SwiftPM build are untouched.

## Requirements

- Xcode 26+ (iOS 26 SDK — AlarmKit is the critical tier)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

The `.xcodeproj` is generated. After changing `project.yml` (or checking out
fresh), run:

```sh
cd iOS
xcodegen
```

Then build/run the `Pauselet` scheme in Xcode, or from the command line:

```sh
xcodebuild -project Pauselet.xcodeproj -scheme Pauselet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Testing

```sh
# Unit tests: the full shared ReminderCore suite on the iOS destination,
# plus the iOS-side planning/mapping tests.
xcodebuild -project Pauselet.xcodeproj -scheme Pauselet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PauseletTests test

# UI smoke tests (launch, tabs, add-reminder flow).
xcodebuild -project Pauselet.xcodeproj -scheme Pauselet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:PauseletUITests test
```

AlarmKit behaviour (breakthrough alerts, Silent-mode piercing, the lock-screen
alarm UI, Apple Watch surfaces) is not meaningfully testable in the simulator;
see Part 5 of the implementation plan for the physical-device matrix. When
alarm authorization is unavailable, critical reminders fall back to
time-sensitive notifications automatically.

## How delivery works (short version)

- Foreground: a 5-second tick drives the engine; subtle reminders show an
  in-app card, normal/important post real notifications, critical shows the
  full-screen takeover.
- Background: everything upcoming is pre-scheduled — critical reminders as
  AlarmKit alarms (weekly/daily recur natively; intervals and grids are
  one-shot fixed-date alarms that get re-armed), the other tiers as
  `UNNotificationRequest`s allocated breadth-first inside the 64-pending cap.
- Every return to the foreground reconciles what the system delivered
  (`recordExternalFire`), absorbs anything stale (`absorbBacklogFromDowntime`),
  and re-schedules.

## Targets

| Target | What it is |
| --- | --- |
| `PauseletiOS` | The app (module name `Pauselet`) |
| `PauseletWidgets` | Widget extension: the AlarmKit Live Activity |
| `PauseletTests` | Unit tests (shared core suite + iOS planners) |
| `PauseletUITests` | UI smoke tests |

Bundle IDs: `com.pauselet.pauselet` (app, matching the Mac build for a future
universal purchase) and `com.pauselet.pauselet.widgets` (extension).
