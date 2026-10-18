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
begin with launching the app. None of Apple's sub-cases apply: there is no
account, no user-generated content and nothing paid.

**Before recording**

- Record from the build that will be reviewed, not from build 58.
- Delete the app from the phone first, so the recording shows a genuine first
  launch with the permission prompts and the four example reminders. A
  reviewer's phone will be in that state.
- Turn on Do Not Disturb for everything except this app, so no personal
  notification appears mid-recording. Check the Lock Screen is clear of
  private content.
- Nothing can be set up inside the app beforehand, because step 1 shows a
  first launch on a freshly installed app. The Critical reminder needed in
  step 5 is therefore created on camera in step 3.
- Have the physiotherapy paragraph ready to paste. Put it in Notes on the
  phone beforehand and copy it, so step 6 is a paste rather than a minute of
  typing.
- Start the capture from Control Centre. Stop it from the red pill at the top
  of the screen.

Editing is fine. Trim pauses, mistakes and waits. Keep each flow whole from
start to finish, and caption any cut that skips time, for example "waiting 60
seconds for the reminder to fire". Do not speed up or splice flows together.

**Narration is not needed.** Apple asks for a screen recording, not a
presentation, and silent ones are normal. The app explains itself on screen,
particularly the level explanations and the settings text, so let the reviewer
read those rather than describing them. Where this shot list says to caption
something, it means on-screen text added in editing, not speech. Captions work
with the sound off and cannot be misheard. Only three captions are really
needed, all noted below: the cut where time is skipped, and the two facts
about the importer that the screen alone does not show.

If you would rather narrate, record silently first and add a voiceover
afterwards, keep it factual, and avoid any medical claim: the app was built
for a pressure-relief routine, it does not prevent anything.

Target length is three to four minutes. Take it slowly enough to read.

**Step 1. Launch, and the permission prompts (about 20 seconds)**

Start on the Home Screen with the Pauselet icon visible, so it is clear the app
is installed on a real device. Tap the icon.

Two system prompts appear in sequence. Tap **Allow** on each, pausing a beat so
both are readable:

- Notifications.
- Alarms, whose text explains that Pauselet schedules alarms so a critical
  reminder such as pressure relief can break through Silent mode and Focus.

This matters more than it looks. It shows the app asks for exactly two
permissions, and that the alarm one is explained at the moment it is requested.

**Step 2. The reminder list (about 25 seconds)**

The app opens on the Reminders tab. Let it sit still for a few seconds before
touching anything, so the reviewer can read it:

- The **Next up** card at the top, naming the next reminder and its countdown.
- The four example reminders installed on first launch: Tilt Back, Weight
  Shift, Drink Water, and Stretch and Range of Motion. Each row shows its
  schedule, a coloured dot for its level, and a countdown.
- The footer count of how many are active.

Tap the pause button at the top left to show the pause
options (30 minutes, 1 hour, 2 hours, indefinitely), then dismiss without
choosing one.

**Step 3. Creating a reminder, and the four levels (about 50 seconds)**

Tap the plus button at the top right. The New Reminder sheet opens. Work down
it deliberately:

This reminder is also the one used in step 5, so make it a Critical one that
repeats every minute. It will then fire during the recording without any
preparation.

1. Type a title: "Pressure relief".
2. Tap an icon in the picker, so the icon changes.
3. Under **Schedule**, tap through **Repeating**, **Daily** and **Weekly** so
   all three are seen, then leave it on Repeating and set the interval to
   **1 minute**, so it fires during the recording.
4. Scroll to **Importance** and stop. This is the most important part of the
   whole recording, because it is what makes the app different. Show all four
   rows and their explanations, which read on iPhone:
   - Subtle: silent, straight to Notification Center, a quiet card in-app.
   - Normal: standard notification, no sound.
   - Important: notification with sound, breaks through Focus modes that
     allow it.
   - Critical: a real alarm, full screen, pierces Silent mode, stays until
     acknowledged.
   Tap **Critical** to select it.
5. Tap **Add**. The new reminder appears in the list, at the top of the
   countdown order because it is due within the minute.

**Step 4. Preview, so a reviewer sees a reminder without waiting (about 30 seconds)**

Open **Drink Water**, one of the examples, scroll to the bottom of the editor
and tap **Preview**. The reminder appears immediately, exactly as it would when
it fires, without altering its schedule or history. This is how a reviewer can
see any level without waiting for it.

Then do the same with **Tilt Back**, which is the Critical example: open it,
tap Preview, and let the full-screen takeover appear. Show that it covers the
screen, that it has a countdown, and that **Done** and **Snooze** are the only
ways out. Tap Done.

No caption needed here; the Preview button is visible in shot.

**Step 5. A Critical reminder arriving for real (about 30 seconds)**

This is the flow Apple most needs to see, because it is the one that uses
AlarmKit, and the reason the app requests the alarm permission.

Lock the phone. Wait for the "Pressure relief" reminder created in step 3 to
fire. Trim the wait in editing and caption the cut.

Show the alarm arriving on the Lock Screen, sounding, and requiring
acknowledgement. Unlock, and show the full-screen takeover with its countdown.
Tap **Done**.

Then toggle "Pressure relief" off in the reminder list, or it interrupts the
rest of the recording every minute. Toggling it off on camera is worth having
anyway, since it shows a reminder being silenced without being deleted.

If Silent mode can be demonstrated safely, flick the Ring/Silent switch to
silent beforehand and let the alarm sound anyway. That is precisely the
behaviour the entitlement exists for.

**Step 6. Exercise reminders and Import from Text (about 60 seconds)**

Tap plus to create a new reminder. Switch the type from **Standard** to
**Exercise**. Give it a title, for example "Morning physio".

Tap **Import from Text**. In the sheet:

1. Paste the prepared paragraph:
   "2 sets of 10 shoulder shrugs, holding for 5 seconds. Then neck rotations:
   1 set of 20 each side. Finally, hamstring stretches: 1 set of 10 reps,
   holding for 30 seconds."
2. Tap **Read Text**. Pause here. The sheet now reads "Found 3 exercises" and
   shows three editable rows with sets, reps, hold and rest filled in.
3. Scroll the rows so all three are seen, and change one number by hand, to
   show nothing is committed until confirmed.
4. Tap **Add 3**.

Back in the editor, the three exercises are listed. Tap **Add** to save the
reminder.

Reopen it, tap **Preview**, and the exercise takeover appears: the programme
listed, "0 of 3 done", **Start All**, and Start and Cancel on each row. Tap
**Start** on the first exercise and let the coach count a repetition or two so
the countdown is visibly running. Tap Done.

**Caption this one.** Two facts the screen cannot show on its own: Read Text
runs entirely on the device with no network request, and the AI alternative
appears only once the user adds their own OpenAI key. These are the two points
most likely to be queried, so state them plainly.

**Step 7. History, Settings, About (about 40 seconds)**

Tap the **History** tab. Show the 24 hours, 7 days and 30 days range picker,
the adherence summary, and the recent activity list with its outcomes.

Tap the **Settings** tab and scroll slowly through, pausing on each section:

- **Quiet Hours**, and the option letting Critical reminders through.
- **Behaviour**: snooze length, how long subtle cards stay, play sounds.
- **Voice Coach**: it is visibly off by default. Turn on **Speak exercise
  cues** and use the Test button so the phone speaks a sample cue. This shows
  the speech is synthesis from installed voices, with no microphone and no
  network. Keep the recording's sound on for this part.
- **Exercise Import**: rest on the empty API key field and its explanatory
  text, which says pasted text is read on the device and that adding a key is
  optional. Leave it empty. The field's own wording is the clearest possible
  demonstration that the OpenAI path is opt-in, so let it be read rather than
  captioning over it.
- **Permissions**: notifications and alarms, both showing Allowed.
- **Data**: the storage location and the statement that everything stays on
  the device with no account and no sync.

Finish on the **About** tab, which names the app, its version and why it was
built.

**What not to include**

- No simulator footage. Apple asked for a physical device.
- Do not sign in to anything or show personal data from other apps.
- Do not demonstrate "Interpret with AI". It needs a real OpenAI key, it is
  optional, and showing it invites questions about a path a reviewer does not
  need to exercise. The empty key field in Settings makes the point better.

### Items 2 to 6: the reply text

App Store Connect's reply field caps at **4000 characters**, so the five
answers are condensed into one block of 3928 characters. It lives in
`docs/app-review-reply.txt` for pasting, and is reproduced here:

```
2. PURPOSE AND TARGET AUDIENCE

Pauselet is a reminder app for recurring physical routines. Each reminder carries its own level of interruption, from a quiet card that fades by itself to a full-screen alarm that must be acknowledged.

Ordinary reminder apps deliver everything at the same volume, so a prompt arriving three times an hour looks identical to one with a medical consequence behind it.

It was written for a wheelchair user who must shift their weight every twenty minutes and tilt their chair back for five minutes every hour, to avoid pressure injuries.

Audience: people with a physical routine to keep. Wheelchair users managing pressure relief, people doing a physiotherapy programme at home, and anyone sitting for long periods who needs movement or posture prompts.

The app makes no medical claim and does not diagnose, monitor or treat anything.

3. SETTING UP AND ACCESSING THE MAIN FEATURES

No login, account or credentials. Nothing is gated. The app works the moment it launches, and installs four example reminders on first launch, one per level.

Permissions: allow notifications and alarms when prompted. Alarms are used only for the Critical level; if declined, Critical reminders fall back to time-sensitive notifications.

The four levels:
- Subtle: silent in-app card
- Normal: standard notification
- Important: notification with sound, reaches through Focus
- Critical: an AlarmKit alarm that sounds through Silent mode, plus a full-screen takeover that stays until acknowledged

To see any level immediately, open a reminder and tap Preview in the editor. It shows the reminder exactly as it will appear without altering its schedule.

Exercise reminders: switch a reminder's type to Exercise and it carries a list of exercises rather than one message. Add rows by hand, or tap Import from Text and paste a handout, for example:

"2 sets of 10 shoulder shrugs, holding for 5 seconds. Then neck rotations: 1 set of 20 each side. Finally, hamstring stretches: 1 set of 10 reps, holding for 30 seconds."

Read Text parses this on the device into editable rows; nothing is added until confirmed. When the reminder fires, Start on a row coaches that exercise, counting each repetition and rest. Start All runs the whole programme.

Voice coach: off by default, enabled in Settings, then speaks cues using voices already installed on the device. No sample files or credentials needed.

4. EXTERNAL SERVICES

Required: none. There is no server, no account system, no analytics, no crash reporting, no advertising identifier and no third-party SDK. Everything is stored in one file inside the app's container.

Optional: OpenAI, used only by the "Interpret with AI" button in the exercise importer. That button does not exist until the user enters their own OpenAI API key in Settings. When used, only the pasted text is sent, directly from their device to OpenAI, with their own key against their own account. We never receive the text or the key. The key is stored in the device keychain, marked this-device-only.

With no key stored, the app makes no network requests at all. The on-device parser handles the same task and is the default. No key is needed to review the app.

Apple frameworks: AlarmKit, UserNotifications, AVFoundation speech synthesis, SwiftUI, WidgetKit.

5. REGIONAL DIFFERENCES

The app functions identically in all regions. No regional content, no server, no geolocation. Scheduling uses the device's own clock, calendar and time zone. English only.

6. REGULATED INDUSTRY OR PROTECTED MATERIAL

Neither applies. The app is not a regulated medical device: it schedules reminders and times exercises the user entered, takes no measurements, and does not diagnose, monitor or treat. The Regulated Medical Device declaration has been answered accordingly.

All exercise content is entered by the user. The app ships no exercise programme, clinical content or licensed material.
```

The same text goes in the Notes field of App Review Information, so later
submissions inherit it. That field has a larger limit, so the longer wording
from earlier drafts could be used there instead if preferred.

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

---

## macOS listing (added 1 October 2026)

The macOS platform was added to the same App Store Connect record, so App
Information, keywords, age rating, privacy answers and pricing are shared with
iOS and need no re-entry. Only the fields below differ, because the Mac app has
a menu bar, overlays on every display, and Spotify.

### Promotional text (170)

```
Reminders that scale from a quiet card to a full-screen takeover on every display, with a voice coach for your physio exercises. Lives in the menu bar.
```
(151 characters)

### Description (4000)

```
Pauselet is a menu bar app that reminds you to move, stretch, drink water and work through the exercises a physiotherapist gave you, with as little ceremony as each reminder deserves.

It was built for a wheelchair user who needed pressure-relief reminders that could not be missed. It turned out to be useful for anyone who sits too long.

FOUR LEVELS OF INTERRUPTION
Every reminder has a priority, and the priority decides how loudly it arrives:
• Subtle: a small card near the menu bar that fades on its own. No sound.
• Normal: a standard notification, in Notification Centre with everything else.
• Important: a card with sound that stays on screen until you tick it done or snooze it, whatever Focus mode or notification style is set.
• Critical: a full-screen overlay on every connected display, which stays until you acknowledge it.

Use Subtle for the nudges you want ten times a day and Critical for the one thing that genuinely cannot wait.

IN THE MENU BAR
Click the icon for a popover showing what is next with a live countdown, every reminder with its schedule, and a button to pause everything. The menu bar itself can show the countdown, or stay quiet. Right-click to pause for 30 minutes, an hour, two hours, or indefinitely. There is no Dock icon and no app-switcher entry.

SCHEDULES THAT MAKE SENSE
• Repeating: every 20 minutes, every 2 hours, measured from the last time it fired.
• Daily: at a fixed time, every day or every few days.
• Weekly: at a fixed time on the days you choose.

Mark a reminder done and it behaves as you would expect. A repeating reminder buys you a full interval of peace, and doing a daily task early uses up today's slot rather than firing again later.

EXERCISE PROGRAMMES WITH A VOICE COACH
A reminder can carry a whole exercise programme: sets, reps, hold times and rests. Press Start and Pauselet counts each repetition and rest for you, or Start All to run the whole programme in sequence. Turn on the voice coach and it speaks every cue aloud, "Set 1, rep 1. Hold for 5 seconds", so your eyes stay off the screen and your form stays intact. The takeover appears on every display, but the coach is shared, so cues are spoken once.

Setting up a programme is fast. Paste the text your physiotherapist wrote and Pauselet reads it into editable rows on your own Mac. Nothing is added until you confirm.

MUSIC
A reminder can start a Spotify playlist when it fires, fading up from silence so it never arrives at last night's volume. Useful for a wind-down, or a stretch you would rather not do in silence. Optional, and the app works fully without it.

SEE WHETHER YOU ARE ACTUALLY DOING THEM
Every firing is recorded as done, snoozed, dismissed or missed. The History tab turns that into a per-reminder adherence summary over the last day, week or month.

QUIET WHEN YOU NEED IT
• Quiet hours silence reminders overnight, with an option to let critical ones through.
• Pause everything for 30 minutes, an hour, two hours, or until you say so.
• A backlog from a night's sleep is absorbed, not replayed.

BUILT FOR ACCESSIBILITY
Every setting has a real explanation button rather than a hover tooltip, so it works with switch control, head pointers and VoiceOver. Overlays are fully keyboard-driven. Times and counts can be typed as well as stepped.

PRIVATE BY DESIGN
No account, no sync, no tracking. Everything stays on your Mac in one plain JSON file you can read and back up. The only optional network feature is interpreting pasted exercise text with AI, which uses your own OpenAI key and is off until you add one.

Pauselet is free, and its source is public. It is also available for iPhone, iPad and Windows.
```
(3629 characters)

### What's New (4000)

```
Pauselet's first release on the Mac App Store.

• Four priority levels, from a quiet card near the menu bar to a full-screen takeover on every display
• Repeating, daily and weekly schedules
• Exercise programmes with a spoken coach that counts every rep and rest
• Paste a physiotherapist's handout to set up a programme in seconds
• A Spotify playlist can start when a reminder fires
• History and adherence, so you can see what you actually did
• Quiet hours and pausing
• Everything stays on your Mac
```

### Screenshots

**Done 1 October 2026.** Eight frames at 2880 x 1800 are in
`dist/mac-app-store-screenshots/` (gitignored). Upload them in numbered order.

| # | Caption | Surface |
|---|---|---|
| 1 | It counts you through your physio programme | The coach mid-hold, countdown ring running |
| 2 | Everything in the menu bar | The popover with Next up and the countdown |
| 3 | When it matters, it takes the screen | The Critical takeover |
| 4 | Paste the handout, not the numbers | The exercise editor section |
| 5 | Four levels of interruption | The editor showing the Importance picker |
| 6 | Quiet hours, snooze, and a voice coach | Preferences |
| 7 | See whether you are actually doing them | History and adherence |
| 8 | Built for one hourly reminder that could not be missed | About, with the origin story and the licence |

**How they are made.** Two steps, both scripted:

```sh
./scripts/build_app.sh
dist/Pauselet.app/Contents/MacOS/Pauselet --snapshot build/ui2x --snapshot-scale 2
python3 scripts/compose_store_shots.py build/ui2x dist/mac-app-store-screenshots
```

The harness renders each surface at its natural size; `--snapshot-scale 2`
doubles the bitmap. `compose_store_shots.py` places each one on a dark
backdrop at 2880 x 1800 with its caption, and holds the caption list, so
changing the wording or the order is an edit to that file. Its `TRIM_BOTTOM`
map crops dead space off a surface whose view is shorter than the frame the
harness renders it in; About needs this, or it scales down to fit empty
pixels.

**Two harness fixes were needed to get here**, both in
`Sources/ReminderApp/SnapshotHarness.swift`:

- `cacheDisplay(in:to:)` stopped capturing SwiftUI text on macOS 26, returning
  shapes and symbols with every label missing. This affected the existing
  documentation screenshots too, not just store assets. The harness now
  captures the window's backing store with `CGWindowListCreateImage`.
- `--snapshot-scale` is new. Without it everything rendered at 1x and had to
  be upscaled, which softened the text.

### Fields that carry over unchanged from iOS

Keywords, Support URL, Marketing URL, Copyright, age rating, App Privacy
(Data Not Collected), and pricing (Free).

### App Review notes for macOS

**Replace the notes entirely.** Adding the macOS platform copies the iOS
notes across, and they are wrong here in three ways that matter:

- They describe AlarmKit, which macOS does not use.
- They say nothing about the App Sandbox or the Spotify exception, which is
  the one thing most likely to cause a rejection.
- They describe tapping and tabs rather than a menu bar.

The replacement is in `docs/app-review-notes-macos.txt` (2957 characters) and
reproduced below. Paste it into the Notes field of App Review Information on
the macOS version page.

```
Pauselet is a menu bar reminder app with no account, no server and no analytics. All data stays on the Mac.

WHERE THE APP IS. Pauselet has no Dock icon and no app-switcher entry by design: it is a menu bar app (LSUIElement). After launching, look for the icon in the menu bar at the top right of the screen. Click it for the popover; right-click it for pause options, Settings and Quit.

THE CENTRAL FEATURE. Each reminder carries its own level of interruption:
- Subtle: a small card near the menu bar that fades on its own, no sound
- Normal: a standard notification
- Important: the app's own card with sound; it stays on screen until ticked done or snoozed, unaffected by Focus or Alert Style
- Critical: a full-screen overlay on every connected display, which stays until acknowledged

To see any of them immediately without waiting: Settings > Reminders, click a reminder to edit it, and press Preview at the bottom of the editor. That shows the reminder exactly as it will appear, without altering its schedule or history. Four example reminders, one per level, are installed on first launch.

APP SANDBOX ENTITLEMENT. The build claims com.apple.security.temporary-exception.apple-events for com.spotify.client. The justification is in the App Sandbox Entitlement Usage Information field. In short: a reminder can start a user-chosen Spotify playlist when it fires, Spotify's AppleScript interface is the only local API for this, Spotify declares no scripting access groups so scripting-targets cannot be used, the feature is opt-in and gated behind the user's own macOS Automation consent, and the app is fully functional without it.

To see the feature: Settings > Preferences > Music, paste any Spotify playlist link, and press Test. macOS will ask for Automation permission. If you decline, reminders still fire, just without music. Spotify does not need to be installed to review the rest of the app; if it is absent the section says so.

EXERCISE IMPORT, AND THE ONE NETWORK FEATURE. A reminder can carry an exercise programme. In the editor, switch the type to Exercise, then "Import from Text" and "Read Text" parses pasted text on the Mac with no network request. An "Interpret with AI" button appears only after the user adds their own OpenAI API key in Settings > Preferences > Exercise Import. That request goes directly from the user's Mac to OpenAI with their own key against their own account; we never receive the text or the key. With no key stored, the app makes no network requests at all. No key is needed to review the app.

NOTIFICATIONS. macOS asks for notification permission on first launch. If it is declined, reminders are shown as the app's own on-screen card rather than being dropped, so nothing is silently lost.

DATA. Everything is stored in one JSON file inside the app's container. There is no account, no sync and no telemetry.

TESTING. This build was verified running under the App Sandbox before submission: it launches, writes its data file, and produces no sandbox denials.
```

One point in it is worth knowing before a reviewer hits it: Pauselet has no
Dock icon, so a reviewer who launches it and sees nothing may assume it
failed. The notes open by saying where to look.

The **App Sandbox Entitlement Usage Information** field is separate from the
notes and must also be filled. That text is in
[mac-app-store-steps.md](mac-app-store-steps.md), step 9.

---

## macOS Guideline 2.1 response (13 October 2026)

The Mac submission drew the same first-submission questionnaire as iOS: a
screen recording plus five written answers. It is not a defect in the app.

The written answers are in `docs/app-review-reply-macos.txt` (3993
characters, under the 4000 cap). They differ from the iOS ones in four ways,
which is why the iOS text cannot be reused:

- No AlarmKit. The Mac uses an overlay on every display for the Critical tier.
- The menu bar, and the warning that there is no Dock icon.
- Spotify, which does not exist on iOS.
- China mainland deselected, mentioned in items 4 and 5.

### The screen recording, on a Mac

Captured on a real Mac, starting with launching the app. Target three to four
minutes. Nothing here needs an account, user-generated content or a purchase,
so none of Apple's sub-cases apply.

**Before recording.** Quit any running copy, and move
`~/Library/Application Support/Pauselet/data.json` aside so the recording
shows a genuine first launch with the four example reminders. Make sure **no
Focus mode is on**: a Focus hides the Normal tier's banner in this build (it
goes straight to Notification Centre), and the recording must show it
arriving. Quit chat and mail apps instead if you want a quiet screen. Have
the physiotherapy paragraph ready to paste. Use QuickTime Player, File > New Screen Recording, and record
the whole screen so the menu bar is visible throughout. The menu bar is where
this app lives, so a window-only recording would miss the point.

**Step 1. Launch (20 s).** Open the app from Applications. Nothing appears in
the Dock, which is correct and worth a caption saying so. Point at the new
icon in the menu bar. macOS 26 asks for notification permission with a
banner at the top right ("Pauselet" Notifications), not a dialog: click the
banner, then click **Allow**. If it has faded, it is waiting in Notification
Centre with the same buttons.

**Step 2. The popover (30 s).** Click the menu bar icon. Rest on it: Next up
with its countdown, the four example reminders with their schedules and
coloured level dots, the pause button. Right-click the icon to show the quick
menu (pause for 30 minutes, an hour, two hours, indefinitely, plus Settings
and Quit), then dismiss it.

**Step 3. The four levels (50 s).** Settings > Reminders, click a reminder to
open the editor. Work down it: title, icon, the three schedule kinds, then
stop on Importance and let all four levels and their explanations be read.
This is the part that explains what the app is for. Click Critical and
pause: the Activity Timer section appears, because only the full-screen
takeover can run a countdown; click Normal and it goes again.

**Step 4. Preview, three levels (60 s).** Still in the editor, press Preview
and let the reminder appear exactly as it would when it fires. Do it three
times, lowest to highest:

- **Drink Water (Normal):** the in-app card for a preview, since a preview
  never posts a real notification. Let it fade on its own.
- **Stretch & Range of Motion (Important):** the sticky card. Leave it on
  screen for a few seconds so it is clear it is not fading, then press
  **Snooze** so both buttons are seen.
- **Tilt Back (Critical):** the full-screen takeover with its countdown,
  requiring Done or Snooze. Press Done.

**Step 4a. A Normal reminder arriving for real (30 s).** Set Drink Water to
Repeating every 1 minute and let it fire: a real macOS notification with
Done and Snooze on the banner. Cut the wait and caption it. This is the one
place the recording shows a system notification, which is what the
notification permission in step 1 was for.

**Step 5. An exercise programme (60 s).** New reminder, type switched to
Exercise. Press Import from Text, paste the handout, press Read Text, show
the three parsed rows, press Add. Save, reopen, press Preview: the programme
appears with Start All and per-row Start and Cancel. Press Start on one and
let the coach count a repetition or two.

**Step 6. Settings and About (40 s).** Preferences: quiet hours, snooze
length, the voice coach (turn it on and use Test so the Mac speaks a cue),
and the Exercise Import section with its empty API key field, which shows the
AI path is opt-in. Then History, then About.

**Captions, not narration.** Only two are needed: any cut that skips time,
and the fact that Read Text runs on the Mac with no network request. The
app's own text does the rest.

**Do not demonstrate "Interpret with AI".** It needs a real key, it is
optional, and showing it invites questions about a path a reviewer does not
need to exercise, particularly after the China ruling.
