# Reminder

A macOS menu bar app for recurring activity reminders, where how *loudly* a
reminder interrupts you is something you choose per reminder.

It was built for a wheelchair user who needs regular pressure relief, so the
central idea is that a medically important prompt and a nice-to-have nudge
should not feel the same. It works just as well for anyone who wants to drink
water, stretch, take medication, or call their mum every Sunday.

Everything is stored locally. There is no account, no sync, and no network
code in the app at all.

<p align="center">
  <img src="docs/images/overlay-critical.png" width="680" alt="Full-screen tilt reminder with a five-minute countdown">
</p>

<p align="center">
  <img src="docs/images/popover.png" width="330" alt="Menu bar popover listing reminders and their countdowns">
  &nbsp;&nbsp;
  <img src="docs/images/settings.png" width="430" alt="Settings window listing reminders with priority and schedule">
</p>

## Priority tiers

The tier decides how the reminder shows up:

| Tier | Presentation |
|---|---|
| **Subtle** | A small silent card in the corner that fades away by itself |
| **Normal** | A standard notification |
| **Important** | A notification with sound, marked time-sensitive |
| **Critical** | A full-screen overlay on *every* display, until you acknowledge it |

Critical is deliberately hard to ignore, because for pressure relief, ignoring
it has consequences. Subtle exists so a frequent nudge (every 20 minutes, all
day) does not become something you learn to tune out.

## Schedules

- **Repeating** — every N minutes, measured from the last time it fired
- **Daily** — at a set time, every N days (so "every second day" stays in phase)
- **Weekly** — at a set time on chosen weekdays

Reminders with a set duration ("tilt back for 5 minutes") show a countdown, so
the prompt is a finite activity rather than an open-ended instruction.

## What ships by default

| Reminder | Schedule | Tier |
|---|---|---|
| Tilt Back | Every hour, 5-minute countdown | Critical |
| Weight Shift | Every 20 minutes | Subtle |
| Drink Water | Every hour | Normal |
| Stretch & Range of Motion | Every 2 days at 17:00 | Important (off by default) |

All of them can be edited or deleted, and you can add your own.

## Other behaviour

- **Quiet hours**, with an option to let critical reminders through anyway
- **Pause** for 30/60/120 minutes or indefinitely; resuming re-anchors the
  intervals so you do not get a backlog dumped on you at once
- **Snooze**, which is authoritative: it will bring a reminder back even if the
  natural next slot is further away, and it fires late rather than vanishing if
  your Mac was asleep at the moment it was due
- **History and adherence**, showing how often each reminder was completed

## Requirements

macOS 13 or later.

## Building

```sh
./scripts/build_app.sh      # builds dist/Reminder.app, ad-hoc signed
open dist/Reminder.app
```

To sign for distribution to other machines:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
```

### Tests

```sh
swift test
```

The scheduling logic is a pure function of `(reminder, now)` with no timers, so
the suite drives a controllable clock and covers overdue catch-up, snooze,
quiet hours, pause, and the multi-day phase behaviour directly.

### Icons

`Resources/icon.svg` is the source of truth; the `.icns` and the menu bar
template images are generated from it:

```sh
./scripts/build_icons.sh
```

### Looking at the UI

```sh
./dist/Reminder.app/Contents/MacOS/Reminder --snapshot build/ui
./dist/Reminder.app/Contents/MacOS/Reminder --open-settings
```

`--snapshot` renders each surface to a PNG, which is easier than trying to
photograph a transient popover.

## Where your data lives

```
~/Library/Application Support/Reminder/data.json
```

Plain JSON — readable, editable, backup-able, and yours.

## Layout

```
Sources/ReminderCore/   Models, scheduler, storage, engine (no UI, fully tested)
Sources/ReminderApp/    Menu bar, overlays, notifications, settings
Tests/                  64 tests against the core
scripts/                Build, icon generation, rasterizer
```

`ReminderCore` deliberately knows nothing about AppKit: the engine hands fired
reminders to a `ReminderPresenting` protocol, which is what makes the firing
rules testable without a screen.
