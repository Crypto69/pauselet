# App Store Connect listing for Pauselet

Everything App Store Connect asks for, ready to paste. Character limits are
Apple's; counts are given where a field has one. The iOS app is the one going
through TestFlight today; the Mac App Store fields are the same text unless a
row says otherwise (see [mac-app-store-submission.md](mac-app-store-submission.md)
for the Mac-only sandbox and Spotify questions).

The description, promotional text and What's New fields are plain text.
Markdown is not rendered there, so paste them exactly as written below.

---

## App Information

| Field | Value |
|---|---|
| Name (30) | `Pauselet` — if the bare name is already taken storefront-wide, use `Pauselet: Break Reminders` (25) |
| Subtitle (30) | `Break & exercise reminders` (26) |
| Bundle ID | `com.pauselet.pauselet` |
| SKU | `pauselet-ios` (any internal string; `pauselet-mac` for the Mac record) |
| Primary language | English (Australia), matching the Phone Vault listing; the app's copy already uses that spelling ("programme", "licence") |
| Primary category | Health & Fitness |
| Secondary category | Productivity |
| Content rights | Does not contain, show or access third-party content |
| Age rating | Answer **None / No** to every question. Result: **4+** |
| Privacy Policy URL | `https://pauselet.com/privacy.html` (the existing policy; it needs the iOS edits listed in [website-handoff.md](website-handoff.md) Part 1 before submission) |
| License agreement | Apple's standard EULA (leave the custom one blank) |

## Pricing and Availability

| Field | Value |
|---|---|
| Price | Free (source available under the PolyForm Noncommercial licence, which forbids anyone else selling it; that is not a reason to charge, just a note that "open source" is no longer the right phrase anywhere in the listing) |
| Availability | All territories |
| Pre-orders | No |
| Distribution | Public on the App Store (not Unlisted, not Apple Business Manager only) |

## App Privacy (the nutrition label)

Answer **"No, we do not collect data from this app."** → label shows **Data Not Collected**.

Why this is correct even with the OpenAI option: Apple counts data as
"collected" when it is transmitted off the device in a way the developer or a
partner can access. The AI import goes from the user's device straight to the
user's own OpenAI account with the user's own key, is opt-in, is clearly
described at the moment of use, and is not part of the app's primary function.
That satisfies Apple's optional-disclosure exemption. Nothing else leaves the
device. Say the same thing in the review notes so the reviewer is not
surprised by a network call.

Tracking: **No**. Privacy manifest: none of the required-reason APIs are used
beyond what Foundation and SwiftUI use themselves, and no third-party SDKs
are linked, so no `PrivacyInfo.xcprivacy` entries are needed.

## Version Information (1.0.0)

### General App Information (the block below the screenshots and description on the version page)

| Field | Value |
|---|---|
| Version | `1.0.0`. Versioning restarted at 1.0.0 on 17 September 2026 with the relicense (`VERSION`, `MARKETING_VERSION` and the only remaining tag all say 1.0.0). It must match `CFBundleShortVersionString` in the build you attach, so check the TestFlight build's version before saving |
| Copyright | `2026 Chris Venter` |
| Age Rating | Set via the questionnaire under App Information: 4+ |
| Routing App Coverage File | Leave empty (only for navigation apps) |

Apple's format for the Copyright field is the year the rights were obtained
followed by the name of the person or entity that holds them, with no URL and
no © symbol needed. Use `2026 MyAccessibility` instead if the nonprofit is the
rights holder; the repository's licence names no holder, and the app's About
screen credits Chris.

### Promotional text (170, can be changed without a new build)

```
Reminders that scale from a quiet nudge to a full-screen alarm, with a voice coach that talks you through your physio exercises. No account, no tracking.
```
(150 characters)

### Description (4000)

```
Pauselet reminds you to move, stretch, drink water and work through the exercises a physiotherapist gave you, with as little ceremony as each reminder deserves.

It was built for a wheelchair user who needed pressure-relief reminders that could not be missed. It turned out to be useful for anyone who sits too long.

FOUR LEVELS OF INTERRUPTION
Every reminder has a priority, and the priority decides how loudly it arrives:
• Subtle: a small card that fades on its own. No sound.
• Normal: a standard notification.
• Important: a time-sensitive notification with sound that can get through a Focus mode.
• Critical: a real alarm that breaks through Silent mode and takes over the screen until you acknowledge it.

Use Subtle for the nudges you want ten times a day and Critical for the one thing that genuinely cannot wait.

SCHEDULES THAT MAKE SENSE
• Repeating: every 20 minutes, every 2 hours, measured from the last time it fired.
• Daily: at a fixed time, every day or every few days.
• Weekly: at a fixed time on the days you choose.

Mark a reminder done and it does what you would expect: a repeating reminder buys you a full interval of peace, and doing a daily task early uses up today's slot rather than firing again later.

EXERCISE PROGRAMMES WITH A VOICE COACH
A reminder can carry a whole exercise programme. Each exercise has sets, reps, a hold time and rest periods. Press Start and Pauselet counts each rep and rest for you, or Start All to run the whole programme with one tap. Turn on the voice coach and it speaks every cue aloud, "Set 1, rep 1. Hold for 5 seconds", so your eyes stay off the screen and your form stays intact.

Setting up a programme is fast: paste the text your physiotherapist wrote and Pauselet reads it into editable rows. Nothing is added until you confirm.

SEE WHETHER YOU ARE ACTUALLY DOING THEM
Every time a reminder fires, the outcome is recorded: done, snoozed, dismissed or missed. The History screen turns that into a per-reminder adherence summary over the last day, week or month.

QUIET WHEN YOU NEED IT
• Quiet hours silence reminders overnight, with an option to let critical ones through.
• Pause everything for 30 minutes, an hour, two hours, or until you say so. A timed pause lifts by itself without a pile-up of overdue reminders.
• A backlog from a night's sleep is absorbed, not replayed.

BUILT FOR ACCESSIBILITY
Every setting has a real explanation button rather than a hover tooltip, so it works with switch control and VoiceOver. Times and counts can be typed as well as stepped.

PRIVATE BY DESIGN
There is no account, no sync and no tracking. Everything stays on your device. The only optional network feature is interpreting pasted exercise text with AI, which uses your own OpenAI key and is off until you add one.

Pauselet is free, and its source is public. It is also available for Mac and Windows at pauselet.com.
```

### Keywords (100, comma-separated, no spaces after commas)

```
break,stretch,exercise,physio,rehab,pressure relief,posture,water,alarm,habit,timer,wheelchair
```
(94 characters)

Do not repeat words that are already in the name or subtitle ("reminders",
"Pauselet"); Apple indexes those fields already.

### URLs

| Field | Value |
|---|---|
| Support URL | `https://pauselet.com/support.html` (page to be added to the site, see the handoff; `https://github.com/Crypto69/pauselet/issues` if the page is not live yet) |
| Marketing URL | `https://pauselet.com` |

### What's New (4000)

For the first App Store release:

```
Pauselet's first release on the App Store.

• Four priority levels, from a quiet card to a real alarm that breaks through Silent mode
• Repeating, daily and weekly schedules
• Exercise programmes with a spoken coach that counts every rep and rest
• Paste a physiotherapist's handout to set up a programme in seconds
• History and adherence, so you can see what you actually did
• Quiet hours and pausing
• Everything stays on your device
```

Later releases: the Mac release notes in `dist/release-notes-<v>.md` are the
right starting point; strip the Markdown headings and the Mac-only sentences.

### Screenshots

App Store Connect currently asks for these sets (check the upload dialog,
Apple changes the list yearly):

| Device | Size (portrait) | Required? |
|---|---|---|
| iPhone 6.5" | 1242 × 2688 | This is the slot App Store Connect shows for this app. One iPhone set covers every iPhone size |
| iPhone 6.9" | 1320 × 2868 | Alternative to the above, not both |
| iPad 13" | 2064 × 2752 | Yes, because the build targets iPad (`TARGETED_DEVICE_FAMILY` 1,2) |
| Apple Watch | none | Skip; there is no watch app |
| Mac | 2880 × 1800 (16:10) | Mac record only |

Up to 10 per set. All three sets are captured and sit in separate directories
under `dist/app-store-screenshots/` (gitignored): `iphone-6.5/`, `iphone-6.9/`
and `ipad-13/`. Upload `iphone-6.5` to the iPhone tab and `ipad-13` to the
iPad tab.

To regenerate, run the capture test per simulator and copy the output out of
`/tmp/pauselet-shots` between runs, because each run overwrites the last:

```sh
cd iOS
TEST_RUNNER_CAPTURE_SCREENSHOTS=1 xcodebuild -project Pauselet.xcodeproj -scheme Pauselet \
  -destination 'platform=iOS Simulator,name=<device>' \
  -only-testing:PauseletUITests/ScreenshotCaptureTests CODE_SIGNING_ALLOWED=NO test
```

The devices that render each size: **iPhone 11 Pro Max** for 1242 × 2688
(create it on iOS 26 with `xcrun simctl create "Pauselet 6.5"
com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max
com.apple.CoreSimulator.SimRuntime.iOS-26-5`), **iPhone 17 Pro Max** for
1320 × 2868, and **iPad Pro 13-inch (M5)** for 2064 × 2752.

Upload order, using the files that exist. The first three show without
scrolling on the store page, so they carry the pitch:

| # | File | What it shows | Note |
|---|---|---|---|
| 1 | `06-takeover-exercise.png` | The Critical takeover with a three-exercise programme (shoulder shrugs 2 × 10 hold 5 s, neck rotations 1 × 20 each side, hamstring stretches 1 × 10 hold 30 s), Start and Cancel per row, Start All, Done and Snooze | The lead image |
| 2 | `01-reminders.png` | The reminder list with Next up and the countdown per row | The four example reminders; the best "what is this app" shot |
| 3 | `02c-import-parsed.png` | Import from Text: the pasted physio paragraph above, the three parsed, editable rows below | The feature no other reminder app has |
| 4 | `02-editor.png` | The editor: Standard/Exercise switch, icon picker, schedule kinds, and the Importance tiers with their one-line explanations | The tier list is cut off at Normal; capture scrolled down if you want all four visible |
| 5 | `04-settings.png` | Quiet hours, snooze length, subtle card time, voice coach, exercise import, permissions | Shows the privacy story in the app's own words |
| 6 | `02b-editor-exercise.png` | The exercise editor holding the imported programme | Optional |
| 7 | `03-history.png` | Adherence and recent activity | Every row reads "Missed" because the simulator sat idle; skip unless recaptured with real completions |
| 8 | `05-about.png` | Why the app exists | Fine as a last slot |

Still not captured: the coach mid-hold with the countdown ring, and a Subtle
card. Both would need the test to press Start and wait, or to fire a subtle
reminder.

The iPad set has the same eight files. Its status bar shows the real clock
rather than 9:41; harmless, fixable with `xcrun simctl status_bar ...
override --time 9:41` before capture if it bothers you.

### App Preview video

Optional. Skip for the first submission.

## App Review Information

| Field | Value |
|---|---|
| Sign-in required | **No** (there is no account) |
| Contact first name | Chris |
| Contact last name | Venter |
| Phone | your number, with country code |
| Email | `support@myaccessibility.ai` |

### Notes for the reviewer

```
Pauselet is a reminder app with no account, no server and no analytics. All data stays on the device.

How to see the four priority tiers quickly:
1. Open the app and allow notifications and alarms when asked.
2. Add a reminder, set it to Repeating every 1 minute, and pick a priority. Subtle shows an in-app card; Normal and Important post notifications; Critical schedules an AlarmKit alarm that breaks through Silent mode and shows the full-screen takeover.
3. The four example reminders installed on first launch also cover one tier each.

AlarmKit: the app uses AlarmKit only for the Critical tier, so a medically necessary reminder (the app was built for a wheelchair user's pressure-relief schedule) cannot be missed. The usage description explains this. If alarm authorisation is denied, critical reminders fall back to time-sensitive notifications.

Exercise import and the one network feature: in the exercise editor, "Import from Text" > "Read Text" parses the pasted text on the device with no network. An "Interpret with AI" button appears only after the user adds their own OpenAI API key in Settings > Exercise Import. That request goes directly from the device to OpenAI using the user's key; we never receive the text or the key. With no key stored, the app makes no network requests at all. No key is needed to review the app.

The Live Activity / widget extension exists only to display the AlarmKit alarm UI; it has no standalone Home Screen widget.

Background modes: "fetch" is used to re-arm upcoming reminders; nothing runs continuously.
```

---

## Responding to the Guideline 2.1 information request

Apple sent this after the first submission on 21 September 2026. It is the
standard questionnaire for a developer account with little review history,
not a defect in the app. The answers below go in two places: the reply in
Resolution Center, and the Notes field of App Review Information so later
submissions inherit them.

### 1. Screen recording (the only item needing new work)

Must be captured on a **physical iPhone** running the current iOS, and must
begin with launching the app. None of the sub-cases apply: there is no
account, no user-generated content and nothing paid. Suggested run, two to
three minutes:

1. Launch from the Home Screen. Allow notifications and alarms when asked.
2. The reminder list: Next up, the countdown, the four example reminders.
3. Add a reminder. Title, icon, Repeating schedule, then the Importance
   picker showing all four tiers and their explanations.
4. A reminder with exercises. Press Preview to show the full-screen takeover
   with Start All and per-row Start and Cancel. Start one exercise so the
   countdown runs.
5. Import from Text. Paste the physiotherapy paragraph, press Read Text, show
   the parsed rows, press Add.
6. History, then Settings: quiet hours, voice coach, exercise import.

### 2. Purpose and target audience

```
Pauselet is a reminder app for recurring physical routines. Its distinguishing
idea is that each reminder carries its own level of interruption, from a quiet
card that fades by itself to a full-screen alarm that must be acknowledged.

The problem it solves: ordinary reminder apps deliver everything at the same
volume. A prompt that arrives three times an hour and a prompt with a medical
consequence behind it look identical, so either the frequent one becomes
unbearable or the important one gets swiped away with everything else.

It was written for a wheelchair user who must shift their weight roughly every
twenty minutes and tilt their chair back for five minutes every hour, to avoid
pressure injuries. That routine has to be unmissable without the frequent
nudges being intolerable.

Target audience: people with a physical routine to keep. Wheelchair users and
others managing pressure relief, people working through a physiotherapy or
rehabilitation programme at home, and anyone who sits for long periods and
needs breaks, movement, hydration or posture prompts.

The app makes no medical claim. It schedules and times reminders; it does not
diagnose, monitor or treat anything, and it is not a regulated medical device.
```

### 3. Setting up and accessing the main features

```
No login, account or credentials are needed. Nothing is gated. The app is
fully functional the moment it launches.

On first launch it installs four example reminders, one per interruption
level, so every feature is reachable immediately.

Permissions: allow notifications and alarms when prompted. Alarms are used only
for the Critical level. If either is declined the app still works, with a
documented fallback (see below).

The four levels, and how to see each one quickly:
- Subtle: a small in-app card that fades on its own, no sound.
- Normal: a standard notification with Done and Snooze buttons.
- Important: a time-sensitive notification with sound, able to reach the user
  through a Focus.
- Critical: an AlarmKit alarm that sounds through Silent mode and Focus, plus a
  full-screen takeover that stays until acknowledged.
To test quickly, add a reminder set to Repeating every 1 minute and choose a
level, or open an existing reminder and press Preview in the editor, which
shows it immediately without altering its schedule.

Exercise reminders: an exercise reminder carries a list of exercises rather
than a single message. Open the editor, switch the type to Exercise, and either
add rows by hand or use "Import from Text". Paste something like:

  2 sets of 10 shoulder shrugs, holding for 5 seconds. Then neck rotations:
  1 set of 20 each side. Finally, hamstring stretches: 1 set of 10 reps,
  holding for 30 seconds.

Press "Read Text" and the app parses it on the device into editable rows.
Nothing is added until confirmed. When the reminder fires, Start on a row
coaches that exercise, counting each repetition and rest; Start All runs the
whole programme in sequence.

Voice coach: off by default. Settings > Voice Coach > Speak exercise cues turns
it on, and it then speaks each cue aloud using the voices already installed on
the device.

No sample files are needed. The pasted text above is the only sample input.
```

### 4. External services, tools and platforms

```
The app has exactly one optional external service, and none that are required.

Required external services: none. There is no server, no account system, no
analytics, no crash reporting, no advertising identifier and no third-party
SDK. All reminders, settings and history are stored in a single file inside the
app's own container.

Optional: OpenAI, used only for the "Interpret with AI" button in the exercise
importer. This button does not exist until the user enters their own OpenAI API
key in Settings > Exercise Import. When used, only the text the user pasted is
sent, directly from their device to OpenAI, authenticated with their own key
against their own OpenAI account. The developer never receives the text or the
key. The key is stored in the device keychain, marked as available on this
device only, so it does not sync via iCloud Keychain.

With no key stored, the app makes no network requests whatsoever. The local
parser ("Read Text") handles the same task entirely on device at no cost, and
is the default. No key is required to review the app, and the AI path can be
ignored entirely during review.

Apple frameworks used: AlarmKit (Critical level alarms and their Live Activity
presentation), UserNotifications (the other levels), AVFoundation speech
synthesis (the voice coach), SwiftUI and WidgetKit.
```

### 5. Regional differences

```
The app functions identically in all regions. There is no regional content, no
region-specific feature, no server and no geolocation. Scheduling uses the
device's own clock, calendar and time zone. The interface is English only at
present.
```

### 6. Regulated industry or protected third-party material

```
Neither applies.

The app is not a regulated medical device and makes no medical claim. It
schedules reminders and times exercises the user has entered themselves. It
does not diagnose, monitor, treat or alleviate any condition, and it takes no
measurements. The Regulated Medical Device declaration in App Store Connect has
been answered accordingly.

Exercise content is entered by the user; the app ships no exercise programme,
no clinical content and no third-party material. There is no protected or
licensed material of any kind in the app.
```

### Also worth including in the reply

```
Testing: the build was tested on a physical iPhone as well as in the
simulator. The automated test suite (348 unit tests) runs on each build.
```

### Version release

**Manually release this version** for the first submission, so approval
does not put it live before the Mac and Windows builds on the same tag are
ready. Automatic release is fine afterwards.

## Build-level settings already handled in the project

| Item | Where |
|---|---|
| Export compliance | `ITSAppUsesNonExemptEncryption: false` in `iOS/project.yml`, so no export questionnaire per build |
| AlarmKit usage string | `NSAlarmKitUsageDescription` in `iOS/project.yml` |
| Version and build number | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, driven by `VERSION` and `scripts/version.sh` on a tag |
| Time Sensitive Notifications | The one capability that needs ticking manually on the App ID in the developer portal |

## Checklist before pressing Submit

- [ ] `https://pauselet.com/privacy.html` has the iOS edits and `https://pauselet.com/support.html` is live
- [ ] Screenshots uploaded: `iphone-6.5` to the iPhone tab, `ipad-13` to the iPad tab
- [ ] App Privacy questionnaire answered: Data Not Collected
- [ ] Age rating questionnaire completed: 4+
- [ ] Phone number entered in App Review contact
- [ ] The build attached is the one that passed TestFlight
- [ ] Version release set to Manual
