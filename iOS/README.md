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

## Exercise reminders

An Exercise reminder carries a list of exercises rather than a message alone,
and iOS is at parity with the Mac on all of it:

- **Editing** — all six fields (name, instructions, sets, reps, hold, and both
  rests) via the shared `ExerciseRowEditor`, plus swipe-to-delete and
  drag-to-reorder.
- **Import from text** — paste what a physiotherapist wrote, press **Read
  Text**, correct anything the parser got wrong in the preview rows, then
  **Add**. The parser is `ExerciseImporter` in the shared core, so a paragraph
  produces the same rows here as it does on the Mac. Nothing is added until you
  confirm.
- **AI import** *(optional)* — with an OpenAI key in Settings › Exercise
  Import, **Interpret with AI** handles wording the local parser cannot. The
  key lives in the keychain (`ThisDeviceOnly`, so it never syncs to iCloud),
  never in `data.json`. With no key stored the app makes no network requests at
  all, and the AI result still goes through the same preview.
- **The guided voice coach** — an exercise with a hold time is coached rather
  than ticked: Start runs the shared `ExerciseSession` timeline, a ring counts
  the current hold or rest down, and with the voice on each phase is spoken
  before it is timed. Untimed exercises keep a plain tick box.

Two iOS-specific behaviours in the coach, both deliberate:

- **Audio session** — cues use `.playback` with `.duckOthers`, so they drop
  music rather than stopping it, and are audible on Silent. The Ring/Silent
  switch is ignored for the same reason the critical tier ignores it.
- **Backgrounding pauses the session.** Leaving the app — including locking
  the screen — pauses a running hold instead of letting it complete unseen,
  mirroring the Mac's pause-on-sleep. Coaching someone through a hold they
  cannot see is worse than waiting for them, so there is no background-audio
  mode.

**Not on iOS:** the Mac's Spotify integration. Music is a desk feature driven
by AppleScript, which has no iOS equivalent; a phone already has a music app a
tap away. `Music.swift` still round-trips the per-reminder choice, so a file
written on a Mac keeps its music settings when opened here.

## Targets

| Target | What it is |
| --- | --- |
| `PauseletiOS` | The app (module name `Pauselet`) |
| `PauseletWidgets` | Widget extension: the AlarmKit Live Activity |
| `PauseletTests` | Unit tests (shared core suite + iOS planners) |
| `PauseletUITests` | UI smoke tests |

Bundle IDs: `com.pauselet.pauselet` (app, matching the Mac build for a future
universal purchase) and `com.pauselet.pauselet.widgets` (extension).
