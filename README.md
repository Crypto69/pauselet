# Pauselet

A menu bar app for macOS that reminds you to move, stretch, drink water, and
work through the exercises a physiotherapist gave you — with as little
ceremony as the reminder deserves.

Everything stays on your Mac. There is no account, no sync, and no telemetry.
The one exception is opt-in and explicit: if you choose to interpret pasted
exercise text with AI, that text is sent to OpenAI using a key you supply.

## The menu bar

Clicking the menu bar icon opens a popover — the everyday surface. It shows
what is coming next with a live countdown, and lists every reminder with its
schedule and priority. From here you can tick a reminder off as done, toggle
one on or off, or pause everything with a single button.

The menu bar itself can show a countdown to the next reminder, so you can see
what is coming without opening anything. That can be turned off if you would
rather keep the menu bar quiet.

Right-clicking the icon opens a quick menu for pausing without opening the
popover: **30 minutes**, **1 hour**, **2 hours**, or **indefinitely**, plus
Settings and Quit. While paused, the popover shows how long is left before
reminders resume.

## Reminders

Each reminder carries a priority, and the priority decides how loudly it
interrupts you:

| Tier | How it arrives |
|---|---|
| **Subtle** | A small self-dismissing card. No sound — for frequent micro-nudges |
| **Normal** | A standard notification that stays in Notification Center |
| **Important** | A notification with sound that persists until acknowledged |
| **Critical** | A full-screen overlay that takes over every display until acknowledged |

### Scheduling

Three kinds of schedule:

- **Repeating** — every *n* minutes or hours, measured from the last time it fired
- **Daily** — at a fixed time, every day or every *n* days
- **Weekly** — at a fixed time on the weekdays you choose

### What else a reminder can carry

- **Title and message** — what it says when it arrives
- **An icon** — chosen from a picker, shown in the popover and on the overlay
- **A countdown** — for reminders describing a timed activity ("tilt back for
  five minutes"), the overlay runs a timer of that length
- **A sound** — the tier default, or a specific one you pick
- **How long a subtle card lingers** — per reminder, overriding the global setting
- **Music** — a Spotify playlist to start when it fires (see below)
- **Exercises** — turning it into an exercise reminder (see below)

## Overlays and keyboard control

Subtle reminders appear as a small card near the menu bar and fade on their
own. Critical reminders take over every connected display until acknowledged.

Overlays are fully keyboard-driven, so you never have to reach for the mouse
mid-stretch:

| Key | Does |
|---|---|
| **Return** | Mark it done |
| **S** | Snooze |
| **1–9** | Tick an exercise off, or start the coach on that row |
| **Space** | Start or pause the voice coach |
| **N** | Next |
| **X** | Stop the coach |

The on-screen hint changes to match what the current overlay can actually do.

## Exercise reminders

An exercise reminder carries a list of exercises rather than a single message.
When it fires it takes over the screen and lists the programme with a tick box
for each exercise, so the whole thing is in front of you while you work
through it, with a running "3 of 5 done" count.

Each exercise has a name, optional instructions, sets and reps, and — when the
movement is held rather than repeated — a hold time and rest periods between
reps and between sets.

### Adding exercises by pasting text

Typing six fields per exercise is the slowest part of setting up a programme,
so you can paste what your physiotherapist wrote instead. In the editor,
choose **Import from Text…** and paste something like:

```
3 sets of 10 chin tucks, holding for 5 seconds, then resting 30 seconds
between sets. Then perform wall slides 3 times for 15 seconds, followed by
30 seconds of rest. Finally, bicep curls: 3 sets of 10 reps, with 30 seconds
of rest between each rep.
```

There are two ways to read it:

**Read Text** parses it on your Mac. No key, no network, no cost. It
understands the phrasings that turn up on a real handout — `3 sets of 10`,
`3 x 10`, spelled-out numbers, `hold 5 seconds`, `rest 30 seconds between
sets`, minutes converted to seconds — across bulleted lists, numbered lists,
and continuous prose that runs one exercise into the next.

**Interpret with AI** sends the text to OpenAI instead, which handles unusual
wording and messy formatting better. It appears only once you have added an
API key.

Either way you get editable rows showing exactly what was understood, and
nothing is added until you confirm. A mis-read costs you an edit, not a wrong
reminder — which matters when the numbers are someone's rehabilitation.

To set up the AI option, go to **Settings → Preferences → Exercise Import** and
paste an OpenAI API key. The key is stored in your macOS keychain, never in the
app's data file. A **Test** button checks the key and model before you rely on
them.

| Model | Notes |
|---|---|
| **GPT-5.6 Luna** | The default. Reads flowing prose well and answers in a few seconds |
| GPT-5 nano | Cheapest per token, but often takes 30 seconds or more to answer |
| GPT-5 mini | Better with unusual wording or long programmes |

Luna is the default rather than the cheapest option on purpose: measured on a
three-exercise paragraph, nano took 31 seconds against Luna's 6, and a
half-minute wait defeats the point of pasting instead of typing. An import
costs well under a tenth of a cent either way.

### The voice coach

An exercise with a hold time can be coached rather than just listed. Press
start on the takeover and Pauselet walks you through the programme set by set
and rep by rep, speaking each cue aloud so you can keep your eyes off the
screen and your form intact:

> "Set 1, rep 1. Hold for 5 seconds." … "Three. Two. One." … "Rest." …
> "Exercise complete."

There is a short lead-in before the first rep, a spoken countdown inside holds
long enough to warrant one, and rests announced between reps and between sets.
Pause, resume, or skip at any point with Space, N and X.

The clock follows real time rather than counting ticks, so a hold is not
shortened if the machine stalls, and the timer freezes while a cue is spoken so
speech never eats into a hold.

The coach is off by default — a talking computer should be a choice. Turn it on
in **Settings → Preferences → Voice Coach**, where you can pick any installed
system voice and set the speaking pace. The **Test** button reads a sample cue
so you can hear a voice before committing to it.

## Music

A reminder can start a Spotify playlist when it fires — useful for a wind-down
or a stretch you would rather not do in silence. Set a default playlist in
**Settings → Preferences → Music** by pasting a Spotify link, and choose the
volume Pauselet fades up to. Each reminder can use that default, pick its own
playlist, or stay silent.

A master switch silences music for every reminder at once — during a meeting,
say — without losing the playlists you have set up. Pauselet drives the Spotify
desktop app directly, so it needs Automation permission the first time; there
is a **Test** button to confirm it works.

## History

**Settings → History** shows what actually happened, over the last **24 hours**,
**7 days**, or **30 days**.

Every time a reminder fires, the outcome is recorded — *fired*, *completed*,
*snoozed*, *dismissed*, or *missed* — and the History tab turns that into a
per-reminder **adherence** summary, plus a list of recent activity. It answers
the question the app exists for: are you actually doing them?

History can be cleared at any time.

## Quiet hours, pausing and sleep

**Quiet hours** silence reminders overnight — 22:00 to 07:00 by default, and
adjustable. Critical reminders can be allowed through anyway, which is on by
default, so something genuinely important is not swallowed by the schedule.

**Pausing** stops everything, either indefinitely or for a set period, from
the popover or the right-click menu.

If the Mac has been asleep or the app closed, Pauselet does **not** replay the
backlog on waking. Reminders whose moment passed hours ago are absorbed rather
than fired all at once. A reminder that merely fell due inside quiet hours is
still delivered when the window ends, because that one has not lost its
meaning.

## Other settings

- **Snooze length** — how long the snooze button defers a reminder
- **How long subtle cards stay on screen** — the global default
- **Play sounds** — master switch for the Important and Critical tiers
- **Show countdown in menu bar**
- **Launch at login**
- **Data** — where `data.json` lives, shown so you can back it up or move it

## Requirements

macOS 13 or later. Notifications need to be allowed for the Normal and
Important tiers to post real system notifications.

## Building

```sh
swift build                 # build the package
swift test                  # run the test suite
./scripts/build_app.sh      # assemble and sign dist/Pauselet.app
./scripts/notarize.sh       # sign, notarize and staple for distribution
```

Notarization matters for more than Gatekeeper warnings: macOS will not grant
notification authorization to an app it does not fully trust, so an
un-notarized build falls back to the app's own card instead of posting system
notifications.

## Layout

| Path | What lives there |
|---|---|
| `Sources/ReminderCore` | Models, scheduling, persistence, the exercise timeline and the text importer. Pure Foundation, no UI, no network |
| `Sources/ReminderUI` | SwiftUI pieces shared between the Mac and iOS apps |
| `Sources/ReminderAI` | The optional OpenAI path and the keychain store — the only code with a route off the machine |
| `Sources/ReminderApp` | The macOS app: menu bar, overlays, notifications, settings, speech |
| `iOS/` | The iOS app, consuming the shared core as a local package |
| `Windows/` | A C# port of the core and a WPF shell, kept byte-compatible with the Mac's data file |

`ReminderCore` deliberately has no network path. Anything that leaves the
machine lives in `ReminderAI`, so the boundary is easy to audit.

Reminders, settings and history live in a single JSON file at
`~/Library/Application Support/Pauselet/data.json`. The Windows port reads and
writes the same file byte-for-byte, so it can be copied between machines.
