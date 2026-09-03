# Pauselet

A menu bar app for macOS that reminds you to move, stretch, drink water, and
work through the exercises a physiotherapist gave you — with as little
ceremony as the reminder deserves.

Everything stays on your Mac. There is no account, no sync, and no telemetry.
The one exception is opt-in and explicit: if you choose to interpret pasted
exercise text with AI, that text is sent to OpenAI using a key you supply.

## Reminders

Each reminder carries a priority, and the priority decides how loudly it
interrupts you:

| Tier | How it arrives |
|---|---|
| **Subtle** | A small hint near the menu bar that fades on its own |
| **Normal** | A standard system notification |
| **Important** | A system notification with a sound |
| **Critical** | A full-screen takeover you have to acknowledge |

Reminders repeat on an interval, daily at a time, or on chosen weekdays. Quiet
hours silence them overnight, with an option to let critical ones through
anyway. Reminders can also start a Spotify playlist when they fire.

## Exercise reminders

An exercise reminder carries a list of exercises rather than a single message.
When it fires it takes over the screen and lists the programme with a tick box
for each exercise, so the whole thing is in front of you while you work
through it.

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
app's data file.

Three models are offered:

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
You can pause, resume, or skip an exercise at any point. The clock follows
real time rather than counting ticks, so a hold is not shortened if the machine
stalls, and the timer freezes while a cue is spoken so speech never eats into a
hold.

The coach is off by default — a talking computer should be a choice. Turn it on
in **Settings → Preferences → Voice Coach**, where you can pick any installed
system voice and set the speaking pace. The **Test** button reads a sample cue
so you can hear a voice before committing to it.

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
