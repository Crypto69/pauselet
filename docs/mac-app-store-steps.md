# Releasing Pauselet on the Mac App Store

*Written 1 October 2026, after the iOS submission. A step-by-step companion to
[mac-app-store-submission.md](mac-app-store-submission.md), which explains the
reasoning; this one is the running order.*

The Mac App Store build is **not** the build you ship today. The direct
download from pauselet.com is Developer ID signed, notarized, and uses the
hardened runtime. The store build drops notarization and the hardened runtime
and instead needs the App Sandbox, two different certificates, an embedded
provisioning profile, and delivery as a signed `.pkg`. Both can coexist: the
direct download stays as it is.

Nothing here is blocked by the iOS submission, and the two share the same App
Store Connect record only if you add macOS as a platform to the existing app
rather than creating a new one. Adding the platform is the right choice: it
gives a single product page and lets a future universal purchase work.

---

## Part 0. Decide the Spotify question first

This is the one step that can sink the submission, so settle it before doing
any of the work below.

The Mac App Store requires the App Sandbox. A sandboxed app cannot send Apple
events to another app, which is exactly how the Spotify feature works, unless
it carries `com.apple.security.temporary-exception.apple-events` listing
`com.spotify.client`. That entitlement works technically but App Review asks
for a written justification, and apps have been rejected over it when the
reviewer judged the feature inessential.

Three options:

| Option | Consequence |
|---|---|
| Ship with the temporary exception plus strong review notes | Keeps the feature. Real but modest rejection risk |
| Compile the Spotify feature out of the store build | Guaranteed clean review. Two feature sets to document |
| Rewrite against the Spotify Web API | Sandbox-clean, but adds OAuth, network code, and requires Premium |

**Recommendation: ship with the exception.** The feature is opt-in, gated
behind the user's own macOS Automation consent, visible in the interface, and
the app degrades gracefully without it. A rejection costs days, not the
feature. The justification text is in step 9.

---

## Part 1. One-time setup in Apple's portals

### Step 1. Create the two Mac App Store certificates

**Checked 1 October 2026.** Neither certificate needed here exists in a form
this build can use.

What the portal holds today, and why none of it works:

| Certificate | Why it cannot sign a store build |
|---|---|
| Developer ID Application (and Managed) | Signs apps distributed outside the store. This is the pauselet.com download. Apple rejects it on store uploads |
| Distribution Managed, All platforms | This *is* an Apple Distribution certificate, created by Xcode for the iOS upload. "Managed" means Xcode holds the private key, so it cannot be downloaded as a usable signing identity for a script |
| Development | Debug builds on your own devices only |
| Apple Sandbox Push Services | A push server certificate for a different app. Not code signing |

Locally, Keychain Access also shows an iPhone Distribution certificate on team
Q8DYXCWMFX, which is the wrong team, and a `localhost` web certificate. Neither
is relevant.

The restriction is deliberate: a certificate records which channel an app came
from, so a store build and a direct download cannot share one. The Developer ID
certificate stays exactly where it is, signing the website download.

**Create both certificates.** Each needs its own certificate signing request,
so this is done twice.

1. Open **Keychain Access**. Menu: Keychain Access, Certificate Assistant,
   **Request a Certificate From a Certificate Authority**.
2. Enter your email address and name. Choose **Saved to disk**. Save the
   `.certSigningRequest` file.
3. Go to
   <https://developer.apple.com/account/resources/certificates/list> and click
   the blue **+**.
4. Choose the certificate type, upload the request file, download the
   resulting `.cer`, and double-click it to install into the login keychain.
5. Repeat from step 1 with a fresh request for the second type.

The two types to create:

| Type to pick in the portal | What it signs |
|---|---|
| **Apple Distribution** | `Pauselet.app` |
| **Mac Installer Distribution** | The `.pkg` uploaded to Apple |

Creating an unmanaged Apple Distribution certificate alongside Xcode's managed
one is allowed. Xcode keeps using its own for iOS.

**Done 1 October 2026.** Both are installed with their private keys. The exact
identity strings, which `build_appstore.sh` refers to by name:

```
Apple Distribution: Christian Venter (4R94388LH8)
3rd Party Mac Developer Installer: Christian Venter (4R94388LH8)
```

To re-verify at any time:

```sh
security find-identity -v           # both, installer included
security find-identity -v -p codesigning   # app signing only
```

The installer certificate appears only in the first listing. That is correct
rather than a fault: it signs installer packages, not code, so the codesigning
policy does not list it. `productbuild` in step 5 still finds it.

**Keep the private keys.** Keychain Access generates a private key per signing
request and keeps it on this Mac. To sign from another machine or from CI,
export the certificate and its key together as a `.p12` rather than
re-downloading the `.cer`. The existing release workflow already does this for
Developer ID, so the pattern is familiar.

### Step 2. Confirm the App ID

`com.pauselet.pauselet` is already registered, since the iOS app uses it. No
change needed. The sandbox and Apple-events exception are entitlement-file
matters, not App ID capabilities.

### Step 3. Create a Mac App Store provisioning profile

Under Profiles, create a **Mac App Store** distribution profile for
`com.pauselet.pauselet` using the Apple Distribution certificate. Download the
`.provisionprofile` file and keep it somewhere stable, for example
`signing/Pauselet_Mac_App_Store.provisionprofile`, gitignored. It expires
yearly and has to be regenerated by hand.

### Step 4. Add macOS to the existing App Store Connect record

In App Store Connect, open the Pauselet app and click **Add Platform**, then
choose macOS. This reuses the name, the privacy answers and the age rating,
and gives one product page covering both. Do not create a second app record.

---

## Part 2. Build the store variant

### Step 5. Write `scripts/build_appstore.sh`

It does not exist yet. It is `build_app.sh` with five differences:

1. **Entitlements.** Replace the current single automation entitlement with
   the sandbox set:

   ```xml
   <key>com.apple.security.app-sandbox</key><true/>
   <key>com.apple.security.files.user-selected.read-write</key><true/>
   <key>com.apple.security.temporary-exception.apple-events</key>
   <array><string>com.spotify.client</string></array>
   <key>com.apple.application-identifier</key>
   <string>4R94388LH8.com.pauselet.pauselet</string>
   <key>com.apple.developer.team-identifier</key><string>4R94388LH8</string>
   ```

   Drop the automation entitlement if you chose to remove Spotify in Part 0.

2. **No hardened runtime.** Remove `--options runtime`. The store rejects it
   alongside the sandbox.

3. **Embed the provisioning profile** before signing:

   ```sh
   cp signing/Pauselet_Mac_App_Store.provisionprofile \
      "$APP/Contents/embedded.provisionprofile"
   ```

4. **Sign with Apple Distribution**, not Developer ID.

5. **Build a `.pkg`** rather than a zip:

   ```sh
   productbuild --component "$APP" /Applications \
     --sign "3rd Party Mac Developer Installer: Christian Venter (4R94388LH8)" \
     dist/Pauselet.pkg
   ```

Two things the current script does that must change for the store: the
`--deep` flag is deprecated and should be dropped, and `LSMinimumSystemVersion`
stays at 13.0, which is fine.

### Step 6. Check the app works under the sandbox

**Done 1 October 2026. The app runs sandboxed with no denials.**

This step exists because a store build **cannot be launched on the machine
that made it**: macOS refuses to run something signed for store distribution,
and `spctl` rejects it. Without a way around that, the first time anyone finds
out whether the sandbox breaks the app is when a reviewer does.

The way around it is `SANDBOX_TEST=1`, which applies the same sandbox
entitlements but signs with Developer ID, so the result launches locally:

```sh
SANDBOX_TEST=1 ./scripts/build_appstore.sh
open "$PWD/dist/Pauselet.app"
log stream --predicate 'sender == "Sandbox"' --style compact
```

It produces no package and must never be uploaded. The script drops the
application-identifier entitlements in that mode, because a Developer ID
signature cannot claim them without a provisioning profile.

**What the test found.** The app launched, created its container, seeded the
four example reminders and wrote a valid `data.json`. No sandbox denials were
logged. Nothing needs changing before submission.

**The data file moves, and that is the one real consequence.** Unsandboxed it
is at `~/Library/Application Support/Pauselet/data.json`. Sandboxed, macOS
redirects that to:

```
~/Library/Containers/com.pauselet.pauselet/Data/Library/Application Support/Pauselet/data.json
```

Nothing breaks for a new user. But someone running the direct download who
then installs the store version will appear to have lost their reminders,
because the two builds read different files. With no external users this is
acceptable; it is worth a line on the website when both are offered.

**Still untested, because they need a human at the keyboard:**

- Notifications. The sandbox does not block `UNUserNotificationCenter`, and
  nothing was denied, but no reminder was allowed to fire during the test.
- Spotify. The temporary exception is in the entitlements and no Apple event
  was denied, but no playlist was actually started.
- The AI import keychain path. No keychain denial appeared, but no key was
  stored during the test.

None of these is likely to fail, since each is either standard sandbox-safe
API or covered by an entitlement that is present. They are listed so the gap
is known rather than assumed away.

### Step 7. Verify before uploading

```sh
codesign -dv --entitlements - dist/Pauselet.app
spctl -a -vvv -t install dist/Pauselet.app
pkgutil --check-signature dist/Pauselet.pkg
```

The entitlements dump must show the sandbox key and the application
identifier. A missing `com.apple.application-identifier` is the single most
common upload rejection.

---

## Part 3. Upload and submit

### Step 8. Upload the package

Install **Transporter** from the Mac App Store, sign in, drag in
`dist/Pauselet.pkg`, press **Verify** first, then **Deliver**. Verify catches
signing and entitlement mistakes locally, before Apple's servers do.

Xcode's Organizer cannot be used here, because the app is built by SwiftPM
rather than from an Xcode project.

Processing takes a few minutes. Failures arrive by email.

### Step 9. Fill the macOS version page

Most metadata is inherited from the iOS listing. What differs:

- **Screenshots.** macOS needs its own, at 2880 x 1800 or 2560 x 1600. The
  repository already renders marketing shots offscreen with
  `--snapshot <dir>`; the existing images in `docs/images/` are a starting
  point but are not store-sized.
- **Description.** The iOS text mentions iPhone behaviour. Swap in the menu
  bar, the four-level overlay on every display, and Spotify.
- **What's New.** Same as the iOS text for a first release.

**App Sandbox Entitlement Usage Information.** If the Spotify exception is in
the build, this field is where the case is made. Paste:

```
The app's core feature is recurring reminders that can start a user-chosen Spotify playlist when they fire, for example calming music during a medically necessary pressure-relief break. Spotify's AppleScript interface is the only local API for this, and Spotify declares no scripting access groups, so com.apple.security.scripting-targets cannot be used.

The feature is opt-in, is configured by the user pasting a playlist link, and is gated behind the user's explicit macOS Automation consent. The app is fully functional without it: if consent is refused, reminders still fire, without music.

The app was built for a wheelchair user who needs reliable pressure-relief reminders.
```

### Step 10. Submit

Attach the processed build, set the release to manual, and submit. Expect one
to three days. If the entitlement is rejected, fall back to Part 0's second
option, strip Spotify from the store build, and resubmit.

---

## What each later release looks like

| Step | Mode |
|---|---|
| Bump `VERSION`, run `build_appstore.sh` | Scripted |
| Regenerate screenshots if the UI changed | Scripted |
| Upload with Transporter | Manual, two minutes |
| Write What's New | Manual |
| Submit | Manual |
| Regenerate the provisioning profile | Manual, yearly |

---

## Open questions for you

1. **Spotify in or out of the store build?** Part 0. Everything else waits on
   this only in the sense that the entitlements file depends on it.
2. **Does the sandbox data-file move need handling?** Step 6. With no external
   users, probably not.
3. **Keep selling the direct download?** The two can coexist, and the direct
   build keeps the hardened runtime and notarization. The website would then
   need to offer both.
