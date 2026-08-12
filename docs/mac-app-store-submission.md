# Submitting Reminder to the Mac App Store

What it takes to get this app from `scripts/build_app.sh` onto the Mac App
Store, in order, with each step marked:

- **[AUTO]** — scriptable; can live in `scripts/` or CI once written.
- **[MANUAL]** — inherently human: portal clicks, judgement calls, writing.
- **[ONE-TIME]** — manual once, then never again (or automatable afterwards).

The existing Developer ID + notarization pipeline (`notarize.sh`) is a
*different* distribution channel and stays as-is for direct downloads. The App
Store build is a parallel variant: **no notarization, no hardened runtime** —
instead it needs the App Sandbox, store certificates, an embedded provisioning
profile, and delivery as a signed `.pkg`. Nothing about being SwiftPM-built
with a hand-assembled bundle is disqualifying; an Xcode project is not
required as long as signing, entitlements, and the profile are right.

---

## Part 0 — The one hard problem: Spotify · [MANUAL, decide first]

Everything else below is routine. This is the step that can sink the
submission, so decide it before spending time on the rest.

The Mac App Store **requires the App Sandbox** (App Review guideline 2.4.5(i)).
A sandboxed app cannot send Apple events to another app — which is exactly how
`SpotifyController` works — unless it carries one of two entitlements:

1. `com.apple.security.scripting-targets` — the supported, review-friendly
   route, but it only works when the *target* app declares scripting "access
   groups" in its sdef. **Spotify declares none**, so this route is closed.
2. `com.apple.security.temporary-exception.apple-events` listing
   `com.spotify.client` — works technically, but App Review requires a written
   justification (the "App Sandbox Entitlement Usage Information" section when
   submitting), and developer-forum history shows apps being rejected for this
   entitlement when reviewers judge the feature non-essential. Approval is
   plausible — the feature is user-visible, opt-in, and clearly explained —
   but it is a genuine rejection risk, not a formality.

Options, in rough order of preference:

| Option | Consequence |
|---|---|
| Ship with the temporary exception + strong review notes | Keeps the feature intact. Risk of rejection and a resubmission cycle. |
| Compile the Spotify feature out of the App Store build | Guaranteed clean review. Two feature sets to document; direct-download version stays the "full" one. |
| Rewrite music playback against the Spotify Web API | Sandbox-clean, but adds network code (the README's "no network code at all" promise dies), OAuth, and playback control requires Spotify Premium. Large effort. |

Recommendation: submit **with** the temporary exception and honest review
notes first — a rejection costs a few days, not the feature — and keep option
2 as the fallback. Whatever the choice, the app must degrade gracefully when
the entitlement is missing (it already does: `SpotifyError.automationDenied`
paths exist).

---

## Part 1 — Accounts, certificates, identifiers

### 1.1 Apple Developer Program membership · [ONE-TIME — already done]
The Developer ID certificate and team ID `4R94388LH8` in the build scripts
mean the paid membership already exists. Nothing to do.

### 1.2 Create the two Mac App Store certificates · [ONE-TIME]
In [Certificates](https://developer.apple.com/account/resources/certificates/list)
(or via Xcode → Settings → Accounts → Manage Certificates):

- **Apple Distribution** — signs `Reminder.app` for the store (the modern name
  for "3rd Party Mac Developer Application").
- **Mac Installer Distribution** — signs the `.pkg` that actually gets
  uploaded.

Install both in the login keychain. (These *can* be created via the App Store
Connect API, but for one machine and one app the portal is faster.)

### 1.3 Register the App ID · [ONE-TIME]
Register `ai.myaccessibility.interlude` as an explicit App ID under
[Identifiers](https://developer.apple.com/account/resources/identifiers/list).
No special capabilities needed — sandbox and Apple-events exceptions are
entitlement-file matters, not App ID capabilities.

### 1.4 Create a Mac App Store provisioning profile · [ONE-TIME]
Under Profiles, create a **Mac App Store Connect / distribution** profile for
that App ID + the Apple Distribution certificate. Download the
`.provisionprofile` file — the build script will embed it (step 2.3). Keep it
in the repo or a known path; it expires yearly and needs regenerating
**[MANUAL, yearly]**.

### 1.5 Create the app record in App Store Connect · [ONE-TIME]
[App Store Connect](https://appstoreconnect.apple.com) → My Apps → **+** →
New App → macOS platform, name "Interlude — Break Reminders" (the working
name; listing names are unique storefront-wide, and the descriptor suffix
keeps the exact string distinctive), primary language, bundle ID from 1.3,
SKU (any internal string).

If the app will be **paid**, also complete the Paid Apps agreement + banking +
tax forms under Business **[MANUAL]**. Free apps skip this entirely.

---

## Part 2 — Make the build App Store–ready

### 2.1 Sandbox the app and verify it still works · [AUTO to build, MANUAL to verify]
Add a store entitlements file (checked into `scripts/` or `Resources/`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <!-- Required by App Store processing; missing them fails after upload. -->
  <key>com.apple.application-identifier</key>
  <string>4R94388LH8.ai.myaccessibility.interlude</string>
  <key>com.apple.developer.team-identifier</key>
  <string>4R94388LH8</string>
  <!-- Only if Part 0 chose to keep Spotify: -->
  <key>com.apple.security.temporary-exception.apple-events</key>
  <array><string>com.spotify.client</string></array>
</dict>
</plist>
```

What the sandbox changes for this app:

- **Data location moves.** `FileDataStore.defaultFileURL` resolves
  Application Support *inside the container*, so the store build writes to
  `~/Library/Containers/ai.myaccessibility.interlude/Data/Library/Application
  Support/Reminder/data.json` with **zero code changes**. There is no existing
  user base yet, so no migration from the old path is needed — a store
  install simply starts with the starter set.
- **Fine as-is:** `UserNotifications`, `SMAppService` launch-at-login,
  `LSUIElement` menu-bar-only apps, the full-screen overlay window, and JSON
  persistence are all sandbox-compatible.
- **Manual verification pass [MANUAL]:** run the sandboxed build and exercise
  every feature — notifications, overlay, snooze, launch at login, Spotify
  consent prompt and playback. Sandbox violations fail silently or with
  obscure Console messages; this is not a "trust the build" step.

### 2.2 Info.plist additions · [AUTO]
In the plist heredoc in `build_app.sh` (or the store variant of it):

- `ITSAppUsesNonExemptEncryption` → `false` — the app has no networking, so
  it is exempt from export compliance; this key answers the question once
  instead of per-upload in App Store Connect.
- `LSApplicationCategoryType` → `public.app-category.productivity` —
  required for store submissions.
- Keep `NSAppleEventsUsageDescription` (still shown for the Automation
  consent prompt) if Spotify stays.

### 2.3 A store build script — `scripts/build_appstore.sh` · [AUTO]
A sibling of `build_app.sh` that:

1. Builds and assembles the bundle exactly as today (reuse the existing
   script with env overrides rather than duplicating it, if practical).
2. Copies the provisioning profile to
   `dist/Reminder.app/Contents/embedded.provisionprofile`.
3. Strips quarantine attributes — since Feb 2025 uploads containing
   `com.apple.quarantine` xattrs are rejected:
   `xattr -rd com.apple.quarantine dist/Reminder.app`.
4. Signs with the store certificate and store entitlements — note **no**
   `--options runtime` (hardened runtime is the Developer ID world; the
   store uses the sandbox):
   ```bash
   codesign --force --deep --timestamp \
     --entitlements scripts/appstore.entitlements \
     --sign "Apple Distribution: Christian Venter (4R94388LH8)" dist/Reminder.app
   ```
5. Wraps it in the uploadable installer package:
   ```bash
   productbuild --component dist/Reminder.app /Applications \
     --sign "3rd Party Mac Developer Installer: Christian Venter (4R94388LH8)" \
     dist/Reminder.pkg
   ```
6. Sanity-checks locally: `codesign --verify --deep --strict dist/Reminder.app`
   and `codesign -d --entitlements - dist/Reminder.app`.

### 2.4 Version discipline · [AUTO]
Every upload needs a `CFBundleVersion` App Store Connect hasn't seen for that
`CFBundleShortVersionString`. The single `VERSION=` variable in
`build_app.sh` currently feeds both; either bump it per upload or derive
`CFBundleVersion` from a counter/commit count so re-uploads never collide.

### 2.5 Toolchain note · [AUTO — just keep Xcode current]
The April 2026 "must build with Xcode 26 / the 26-era SDKs" floor currently
applies to iOS-family platforms, **not macOS** — but Apple adds platforms to
that list over time, so build store submissions with the current release
Xcode toolchain and treat it as a standing requirement.

---

## Part 3 — Store listing assets and metadata

### 3.1 Screenshots · [AUTO — extend `SnapshotHarness`]
1–10 screenshots, 16:10, in one of: 1280×800, 1440×900, 2560×1600, or
2880×1800 px. The repo already renders marketing shots offscreen via
`SnapshotHarness` — extend it to emit 2880×1800 renders of the overlay,
menu, editor, and settings, and screenshot production becomes a build step.

### 3.2 Written metadata · [MANUAL, ~an hour]
Description, promotional text, keywords (100 chars), support URL (the GitHub
repo qualifies), and a marketing URL. The README already contains 90% of the
prose. Uploading these *can* be automated later with `fastlane deliver`, but
writing them is a human job.

### 3.3 Privacy policy + privacy "nutrition label" · [MANUAL, easy here]
- A **privacy policy URL is mandatory** for every app, even one that collects
  nothing. A short page (or a `PRIVACY.md` rendered via GitHub Pages) saying
  everything stays on-device suffices.
- The App Privacy questionnaire in App Store Connect: with no network code,
  the answer is simply **"Data Not Collected"** — a five-minute task.

### 3.4 Age rating questionnaire · [MANUAL, one-time]
Complete the (recently expanded) age-rating questionnaire in App Store
Connect; for this app everything is "No" → rated 4+.

### 3.5 Pricing and availability · [MANUAL, one-time]
Pick free/paid and territories. (See 1.5 for the paid-app paperwork.)

---

## Part 4 — Upload the build

### 4.1 First upload — Transporter app · [MANUAL]
Install [Transporter](https://apps.apple.com/app/transporter/id1450874784)
from the Mac App Store, sign in with the Apple ID, drop in `dist/Reminder.pkg`,
hit **Verify** (catches signing/entitlement mistakes before Apple's servers
do), then **Deliver**. Post-upload processing takes a few minutes; failures
arrive by email (missing `application-identifier` entitlement and stray
quarantine xattrs are the classic ones — both handled in Part 2).

### 4.2 Repeat uploads — scripted · [AUTO, after one-time API key setup]
For CI or one-command releases:

1. **[ONE-TIME]** Create an App Store Connect **API key** (Users and Access →
   Integrations) with App Manager role; store the `.p8` securely.
2. **[AUTO]** Upload with the Transporter CLI (`iTMSTransporter`, installed
   with the Transporter app) authenticating via that key, or — simpler —
   `fastlane deliver` / `fastlane pilot`, which wrap the same machinery and
   also push metadata and screenshots. Note: from 2026 Transporter requires
   `-assetFile` rather than the old `-f` flag for the package path.

`xcrun altool --upload-app` still exists but is formally deprecated (TN3147);
don't build new automation on it.

### 4.3 (Optional but recommended) TestFlight round · [MANUAL trigger, AUTO delivery]
Any uploaded build can go to TestFlight for Mac (testers need macOS 12+ and
the TestFlight app). Internal testers get builds almost immediately; external
testers require a lightweight beta review. Worth one round to shake out
sandbox issues on a machine that isn't the dev box.

---

## Part 5 — Submit for review

### 5.1 Attach the build and fill the review form · [MANUAL]
In the version page: select the processed build, add review notes and a
contact. **If the Apple-events exception is in the entitlements, this form is
where the case is made** — in the App Sandbox Entitlement Usage Information /
review notes, state plainly:

> The app's core feature is recurring reminders that can start a
> user-chosen Spotify playlist when they fire (e.g. calming music during a
> medically necessary pressure-relief break). Spotify's AppleScript
> interface is the only local API for this; Spotify defines no scripting
> access groups, so `scripting-targets` cannot be used. The feature is
> opt-in, gated behind the user's explicit macOS Automation consent, and
> the app is fully functional without it.

Mentioning the accessibility origin (built for a wheelchair user's pressure
relief) is both true and genuinely relevant to the reviewer's judgement.

### 5.2 The review itself · [MANUAL — wait and respond]
Typically 1–3 days. Possible outcomes: approved; rejected over the
entitlement (fall back to Part 0's option 2 — strip Spotify from the store
build — and resubmit); or a metadata/clarification round-trip in Resolution
Center. Choose manual or automatic release of the approved version.

---

## Part 6 — Steady state: what each later release looks like

Once Parts 1–3 are done, a release is:

| Step | Mode |
|---|---|
| Bump version, build, sign, package (`build_appstore.sh`) | **[AUTO]** |
| Regenerate screenshots if UI changed (`SnapshotHarness`) | **[AUTO]** |
| Upload pkg + metadata (`fastlane deliver` / Transporter CLI) | **[AUTO]** |
| Update "What's New" release notes text | **[MANUAL]** (5 min) |
| Click Submit for Review (or script it via fastlane) | **[AUTO-able]** |
| Respond to review feedback | **[MANUAL]** (rare) |
| Renew provisioning profile / certificates | **[MANUAL]** (yearly) |

The bottom line: roughly a day of one-time setup (Parts 1–3), one genuinely
uncertain review question (the Spotify entitlement), and after that the
repeatable path is almost entirely scriptable — in keeping with how this repo
already ships the Developer ID build.

---

## References

- [App Review Guidelines §2.4.5 (Mac sandbox requirement)](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
- [App Sandbox temporary exception entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- [Upcoming App Store submission requirements (SDK floors, quarantine xattr rule)](https://developer.apple.com/news/upcoming-requirements/)
- [Uploading builds — App Store Connect help](https://www.developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Transporter release notes (the 2026 `-assetFile` change)](https://developer.apple.com/transporter/release-notes)
- [TN3147: altool deprecation](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Creating an App Store provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)
