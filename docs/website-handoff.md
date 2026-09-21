# pauselet.com: changes needed before the App Store release

*Written 17 September 2026 in the app repository, for whoever works on the
website repository (`pauseletweb`, deployed to https://pauselet.com from
`dist/` via Firebase Hosting). Everything below was checked against the app's
code and README at version 1.0.0, not against older docs. The number is not a typo: versioning was restarted at 1.0.0 on 17 September 2026 when the app was relicensed, and the old 1.x tags and releases are gone.*

The site was last updated on 4 September 2026 and describes the macOS app as
it stood on 4 September (the old 1.3.0, before the version reset). Since then the app has shipped on iOS and Windows, the
exercise coach has been reworked, and the iOS app is about to be submitted to
the App Store. App Store Connect will link to this site for three things:
the privacy policy, support, and marketing. The privacy page currently says
it applies only to the macOS app, which a reviewer of an iPhone build can
read as "does not cover this app". That is the one change that blocks
submission. Everything else is catch-up.

Three parts, in priority order:

1. **Part 1**: what App Review needs. Do this first.
2. **Part 2**: the home page needs to say the app exists on iPhone, iPad and
   Windows.
3. **Part 3**: a feature-by-feature audit of the site copy against the app as
   it is today, with what to change.

House style stays as it is: no em dashes in the copy (there is a commit
removing them), British spelling, plain sentences.

---

## Part 1: what App Review needs

### 1.1 `dist/privacy.html`: widen it to all three platforms

Apple requires a privacy policy URL that covers the app being reviewed. The
policy is accurate for the Mac and nearly everything in it is true on every
platform, so this is editing, not rewriting.

| Where | Now | Change to |
|---|---|---|
| Scope line (near line 70) | "Applies to the Pauselet macOS app and this website" | "Applies to the Pauselet apps for macOS, iOS and Windows, and this website" |
| `<meta name="description">` and `og:description` | "stays in one file on your Mac" | "stays in one file on your device" |
| "Data the app stores on your Mac" | Only the Mac path | Keep the Mac path. Add: on iPhone and iPad the same file lives inside the app's own container, and is included in an iCloud or computer backup of the device under the user's own backup settings. On Windows it is in `%LOCALAPPDATA%\Pauselet\data.json`. The file is the same format on all three, so it can be copied between machines. |
| Keychain paragraph (near line 136) | "stored in your macOS keychain" | "stored in the device's keychain (on iOS marked as available on this device only, so it is not synced through iCloud Keychain; on Windows encrypted with Windows Data Protection under your user account)". The rest of the paragraph stands: never in `data.json`, cleared when you remove it in Preferences. |
| "Permissions Pauselet asks for" | Notifications and Automation, both described as macOS | Say Notifications is asked for on every platform. Mark Automation (Apple Events) as **Mac only**. Add a third entry: **Alarms (iOS only)**. "So a Critical reminder can be scheduled as a real alarm that sounds through Silent mode and a Focus, shows on the Lock Screen, and cannot be swiped away without being acknowledged. Only the Critical volume uses it. If you decline, Critical reminders fall back to time-sensitive notifications." Keep the sentence "No microphone, no camera, no contacts, no location, no full disk access". |
| "AI exercise import" | "from your Mac to OpenAI" | "from your device to OpenAI" (two places, near lines 180 and 200) |
| "The voice coach" | "voices already installed in macOS", "no audio leaves your Mac" | "voices already installed on your device" and "no audio leaves your device". On Windows the voices are the ones Windows Speech provides. |
| "Spotify" | Describes the Mac | Add one sentence at the top: "Music is a Mac-only feature. The iOS and Windows apps do not talk to Spotify at all." |
| Last-updated date | 4 September 2026 | The date the edit ships |

Do not add anything about analytics, accounts or sync: there still are none on
any platform.

### 1.2 Add `dist/support.html`

App Store Connect's Support URL must reach a page with actual support
information. The site has no such page and the home page shows no contact
address. A short page is enough:

- Heading: "Pauselet support".
- Email: support@myaccessibility.ai (the address the app's About screen uses).
- A link to https://github.com/Crypto69/pauselet/issues for bugs and requests,
  with a line saying the source is public and issues are public.
- Three or four common questions with one-paragraph answers, all of which are
  already answered in the README:
  - "Normal and Important reminders show as a card inside the app instead of a
    notification": notifications were declined, or on the Mac the build is not
    notarised. Allow notifications in System Settings or Settings and Pauselet
    switches back by itself.
  - "A Critical reminder on iPhone arrived as a notification, not an alarm":
    Alarms permission was declined. Allow it in Settings > Pauselet.
  - "Where is my data?": the file locations from the privacy page.
  - "Interpret with AI does not appear": it appears only after an OpenAI key
    is added in Settings > Exercise Import. Read Text needs no key.
- Link it from the footer next to Privacy.

Same header, footer and stylesheet as the privacy page.

### 1.3 Confirm the URLs App Store Connect will use

| Field | URL |
|---|---|
| Privacy Policy URL | https://pauselet.com/privacy.html |
| Support URL | https://pauselet.com/support.html |
| Marketing URL | https://pauselet.com |

Both `.html` addresses must keep working. If you add clean URLs in
`firebase.json` (`"cleanUrls": true`) keep the `.html` paths reachable too,
because the store listing may be submitted before the site change ships.

---

## Part 2: the home page has to say what the app runs on

The `<title>`, both meta descriptions, the eyebrow "Menu bar app · macOS 13+",
the hero button "Download for macOS", the "Get Pauselet" section and the
footer all say macOS and nothing else. The app now ships on three platforms
from one release tag, and the iOS app is going to the App Store.

| Where | Change |
|---|---|
| `<title>` | "Pauselet: recurring reminders at the volume you choose" (drop "for macOS") |
| Meta and og descriptions | "A reminder app for Mac, iPhone, iPad and Windows where you set how loudly each reminder interrupts you..." |
| Eyebrow above the hero | "Mac · iPhone and iPad · Windows" |
| Hero button | Keep one primary "Download" that scrolls to the download section, which now has three choices |
| "Get Pauselet" section | Three columns or three rows: **Mac** (unzip, drag to Applications, signed and notarised, macOS 13 or later), **iPhone and iPad** (App Store badge linking to the App Store page once it is live; iOS 26 or later; until it is live say "Coming to the App Store" with no link), **Windows** (self-contained zip, Windows 10 version 1809 or later, no .NET to install, about 75 MB, unzip and run `Pauselet.exe`). All three link to https://github.com/Crypto69/pauselet/releases/latest except the App Store badge. |
| Footer | Add "Support" next to Privacy |
| "Your data" section | The JSON file line can stay, but say "on your device" and mention that the same file is read by all three apps, so it can be copied between a Mac and a Windows machine |

Apple's App Store badge artwork and its usage rules are at
https://developer.apple.com/app-store/marketing/guidelines/. The App Store
URL is not known until the app is approved; leave a placeholder that is easy
to find.

Platform differences worth one line each, so nobody expects a feature the
platform does not have:

- **Music (Spotify) is Mac only.** It drives the Spotify desktop app through
  AppleScript. iOS has no equivalent and Windows has deliberately not
  implemented it.
- **The menu bar popover is Mac only.** On iOS the main screen is the
  reminder list with the next-due countdown at the top. On Windows there is a
  tray icon with a flyout that shows the same thing.
- **On iPhone, Critical reminders are real alarms** (AlarmKit): they sound
  through Silent mode and Focus, show on the Lock Screen, in the Dynamic
  Island and in StandBy as a Live Activity, and must be acknowledged. In the
  foreground they take over the screen like the Mac.

---

## Part 3: feature audit, site copy versus the app today

Method: the whole text of `dist/index.html` was read against the app's
README, the pre-reset release notes, the code, and the parity document in the app
repository. Each row says whether the site is right, wrong, or silent, and
what to do. The rows marked **wrong** describe behaviour the app no longer
has and should be fixed before anything is added.

### 3.1 Wrong: the exercise takeover no longer has tick boxes

This is the biggest change since the site was written. On 7 September the
coach was widened to every exercise, and tick boxes were removed.

| Site says | App does now | Action |
|---|---|---|
| "When it fires, the programme is on the screen in front of you with a tick box on each row" | Every row has **Start** and **Cancel**. Pressing Start coaches that exercise; the coach marks it done when the last set finishes. Cancel means "skipping it this time". There is no manual tick. | Rewrite the "Exercises" intro paragraph |
| "1–9 to tick" card, "Ticked off as you go... Number keys tick a row" | Number keys **1 to 9 start the coach on that row**. **A** starts every exercise still to do, in order. | Rewrite the card as "1–9 to start a row, A to start them all" |
| "Finished when you say... The count is there so a half-done programme looks half-done" | The "3 of 5 done" count is still there. What finishes an exercise is the coach, not a tick. | Keep the count, change the sentence about ticking |
| Keyboard-driven overlays card: "number keys to tick an exercise" | "number keys to start an exercise, A to start them all" | One-word edit |
| Voice coach section implies only exercises with a hold time are coached | **Every exercise is coachable.** A movement with a hold time has each rep counted down. One without a hold is paced at three seconds a rep, counted aloud ("Set 1, rep 1. Rep 2. Rep 3."), so it runs through on its own. | Add a sentence to the voice coach section |

### 3.2 Missing: Start All and the rest between exercises

Not on the site at all. This is the feature that turns a list into a
programme you can run with one press.

- **Start All** (button on the takeover, or the A key) runs every exercise
  still to do, in order, as one continuous session: a short "Get ready"
  lead-in, the sets and reps, then a rest before the next exercise.
- **Rest between exercises is set per reminder** in the editor, and the field
  only appears once a reminder has two or more exercises.
- The coach announces hand-overs: "Pelvic tilts complete. Rest for 30 seconds.
  Next, Chin tucks." With no rest configured it says "Pelvic tilts complete.
  Chin tucks. Get ready."
- Cancelling the exercise being coached mid-run jumps straight to the next
  one's lead-in. The session ends with "All exercises complete".
- Sets default to **one**, not three: if the handout does not say a number of
  sets, it means one set. This applies to the editor, the text parser and the
  AI import.
- **Exercises can be reordered** in the editor: up and down arrows beside
  each row on Mac and Windows, drag to reorder on iOS.

Suggested placement: a fourth card in the "Exercises" section, and one
paragraph in the voice coach section.

### 3.3 Missing: exercise reminders are always Critical

An exercise reminder is always delivered at the Critical volume; the editor
does not let you pick a lower one. The README's reason is worth quoting: "a
programme you can dismiss without seeing is not a programme". One line in the
Exercises section.

### 3.4 Voice coach: mostly right, a few additions

The section is accurate about real-time clocks, the timer freezing while a
cue is spoken, pause on sleep, opt-in, voice choice and pace. Add:

- The spoken "three, two, one" happens only inside holds long enough to
  warrant one; the short lead-in before the first rep; rests are announced
  between reps, between sets and between exercises.
- Quiet chimes mark each phase change and the end of an exercise, following
  the global "Play sounds" setting.
- A **Test** button in Preferences reads a sample cue so you can hear a voice
  before committing to it.
- Higher-quality voices can be downloaded in System Settings > Accessibility >
  Spoken Content > System Voice (Mac). On iOS the Settings equivalent is
  Accessibility > Spoken Content > Voices.
- On iPhone, cues duck other audio rather than stopping it and are audible on
  Silent. Leaving the app or locking the screen pauses a running session
  rather than letting a hold complete unseen.

### 3.5 Text import: right, one addition

"Read Text" and "Interpret with AI" are described correctly, including the
models table and the reason Luna is the default. Add that the parser
understands rest between reps as well as between sets, and that on iOS and
Windows the same parser and the same AI option exist (on Windows the key is
protected with Windows Data Protection rather than a keychain).

### 3.6 Menu bar and popover: silent on several things

| Feature | Site | Action |
|---|---|---|
| Countdown to the next reminder shown **in the menu bar itself**, switchable off | Not mentioned | Add to "At a glance" |
| Right-click the icon for a quick menu: pause 30 min, 1 hour, 2 hours, indefinitely, plus Settings and Quit | Not mentioned (pausing is, the right-click route is not) | Add to "At a glance" |
| Hover a row for a tick button; an overdue row turns orange and reads "due" | Not mentioned | Optional, one line |
| No Dock icon, no app-switcher entry | Not mentioned | One line in the download section |
| While paused, the popover shows how long until reminders resume | Not mentioned | Optional |

### 3.7 Reminders and the editor: silent on several things

- **Duplicate** a reminder from the right-click menu in Settings > Reminders.
  Delete asks first because it takes the reminder's history with it.
- Four **example reminders**, one per volume, are installed on first launch.
- **Per-reminder sound**: the volume's default or a specific sound, auditioned
  as soon as you pick it.
- **Preview** in the editor shows the reminder exactly as it will appear,
  sound and music included, without touching its schedule or history. The site
  has this; add "sound and music included".
- Each volume is explained in the picker (the site has this).
- Playlist, album and track links are all accepted for music, in either the
  `spotify:` or `open.spotify.com` form.

### 3.8 Notifications: silent on the details that make them trustworthy

- Banners carry **Done** and **Snooze** buttons. Clicking the body marks it
  done; swiping it away records it as dismissed.
- Important reminders are sent as time-sensitive so they can reach you through
  a Focus (site has this).
- If notifications are denied, the reminder is shown as an in-app card rather
  than dropped, and an Important one stays for a full minute (site has the
  fallback, not the minute).
- Pauselet **checks that each notification actually arrived** and switches
  back to system notifications by itself once permission is granted.

### 3.9 Quiet hours, pausing, done, sleep: two corrections and two gaps

- **Correct on the site:** if the Mac was asleep, a reminder fires late
  rather than vanishing. Keep it.
- **Gap:** quitting the app and relaunching it hours later does **not** replay
  the backlog. Anything that came due more than two minutes before launch is
  absorbed, because a reminder is "a request to be interrupted at a moment,
  not a debt that accrues while nobody is listening". A reminder that fell
  due inside quiet hours is still delivered when the window ends. Worth a
  sentence next to the sleep one so the two are not confused.
- **Gap:** inside quiet hours a **repeating** reminder is held and delivered
  when the window ends, but a **daily or weekly** one scheduled at a quiet
  time is skipped and recorded as missed: "daily at 23:00" should not arrive
  at 07:00. The menu bar countdown accounts for this.
- **Gap:** what "done" means per schedule. Repeating: done buys a full
  interval of peace. Daily and weekly: doing it early consumes the upcoming
  slot instead of letting it fire again hours later. The site's "finishing
  early resets the clock" covers the repeating case only.
- **Gap:** reminders that fire while another is on screen are queued, and
  anything that has waited more than two minutes is discarded as missed when
  you acknowledge, so coming back to the desk does not mean dismissing
  takeover after takeover.
- **Gap:** a timed pause expires by itself and re-anchors repeating
  reminders to the moment it lifts. The site says "resuming re-anchors the
  intervals"; add that timed pauses lift on their own.

### 3.10 History: add the ranges and the clear button

The site says history and adherence exist. Add: the ranges are 24 hours, 7
days and 30 days; every firing is recorded as fired, completed, snoozed,
dismissed or missed; history can be cleared at any time.

### 3.11 Music: silent on the controls

The section is right about fading up, per-reminder choice and the Automation
prompt. Add:

- A **master switch** silences music for every reminder at once, for a
  meeting, without losing the playlists.
- Marking a reminder done or snoozing it **stops the music it started**, but
  music you started yourself is never touched.
- A **Test** button confirms the Spotify connection; if permission was
  refused, the app links straight to the right System Settings pane. If
  Spotify is not installed the section says so and everything else works.
- Mac only (see Part 2).

### 3.12 Settings: the list is longer than the site shows

Not on the site: snooze length (1 to 120 minutes, 5 by default); how long a
subtle card stays (2 to 60 seconds, 8 by default, overridable per reminder);
"Play sounds" master switch for Important and Critical; the data file
location is shown and selectable so you can back it up; times and counts can
be typed as well as stepped, and out-of-range values are clamped rather than
rejected. The "(i) button on every setting" card is right and worth keeping.

### 3.13 About: links

The About screen links to myaccessibility.ai, the MyAccessibility YouTube,
Instagram and LinkedIn pages, and the support email. The site's "Also from
Chris" block links only to the website. Optional: add the social links there.

### 3.14 iOS: nothing on the site yet

Everything from the Mac applies (volumes, schedules, exercises, coach,
import, history, quiet hours, pausing) except music and the menu bar. iOS
specifics worth a short section or a column in a platform table:

- **Critical reminders are alarms** (AlarmKit): sound through Silent mode and
  Focus; Lock Screen, Dynamic Island and StandBy presentation via a Live
  Activity; must be acknowledged. Requires the Alarms permission; with it
  declined they fall back to time-sensitive notifications.
- Subtle: an in-app card. Normal and Important: real notifications with Done
  and Snooze. Critical in the foreground: the full-screen takeover.
- Reminders keep firing with the app closed: everything upcoming is
  pre-scheduled and reconciled when the app returns.
- Runs on **iPhone and iPad**, portrait on iPhone, all orientations on iPad.
- Drag to reorder exercises; swipe to delete.
- OpenAI key in the keychain, marked this-device-only.
- Requires **iOS 26** or later.

### 3.15 Windows: nothing on the site yet

- Tray icon with a hover tooltip showing the next reminder and countdown, and
  a flyout with Next up, the reminder list, pause and settings.
- Subtle card, toast notifications with Done and Snooze for Normal and
  Important, full-screen critical overlay.
- Exercise reminders, the coach with Windows voices, Read Text and AI import
  (key protected by Windows Data Protection).
- Reads and writes the **same data.json byte for byte** as the Mac, so a file
  can be copied between machines.
- No music.
- Windows 10 version 1809 or later, x64. Self-contained: nothing to install
  first.

### 3.16 Small factual checks on existing copy

- **Wrong:** "Free and open source", "Price Free, MIT licensed", the footer
  "MIT licence" link and the About paragraph's "free, open source". The app
  was relicensed on 17 September 2026 under the **PolyForm Noncommercial
  1.0.0** licence, which is source-available, not open source (it restricts
  commercial use, which the OSI definition does not allow). The app's own
  About screen now reads: "Free to use and share for any noncommercial
  purpose. Source available under the PolyForm Noncommercial licence." Use
  that wording. Point the footer's licence link at the same LICENSE URL,
  which now holds the PolyForm text. "Signed and notarised by Apple · No
  account" stays true.
- The data.json example uses `activityDurationSeconds` and `priority`: still
  the real field names.
- "Requires macOS 13 or later": still true.
- The models table (GPT-5.6 Luna default, GPT-5 nano, GPT-5 mini) matches the
  app.
- The four example reminders shown in the mock-ups (Weight Shift, Drink Water,
  Take Medication, Tilt Back) match the app's first-launch examples.

---

## Checklist

- [ ] `privacy.html` scope, storage, keychain, permissions (Alarms added,
      Automation marked Mac only), voice, Spotify, date
- [ ] `support.html` created and linked from the footer
- [ ] Home page title, meta, eyebrow, download section and footer cover Mac,
      iPhone and iPad, Windows
- [ ] App Store badge placeholder in the download section
- [ ] Exercise section: tick boxes removed from the copy; Start/Cancel,
      Start All, rest between exercises, every exercise coachable, sets
      default to one, reordering
- [ ] Keyboard cards: 1–9 starts a row, A starts all
- [ ] Every "open source" and "MIT" replaced with the PolyForm Noncommercial wording (hero line, download section, footer, About)
- [ ] The rest of Part 3 as time allows, in the order given
- [ ] Deploy, then open https://pauselet.com/privacy.html and
      https://pauselet.com/support.html and confirm both return 200
