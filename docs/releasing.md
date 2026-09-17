# Releasing Pauselet

One tag releases all three platforms. Pushing `v1.0.0` builds, tests and
publishes a Mac app, a Windows app and an iOS archive as a single GitHub
Release, so a change to the shared core cannot reach Mac users while quietly
missing everyone else.

## Cutting a release

1. Bump `VERSION` at the repository root — the one place the number lives.
2. Commit it.
3. Tag and push:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

4. Watch it at <https://github.com/Crypto69/pauselet/actions>. It takes roughly
   ten minutes, most of it Apple's notary service.

The tag is authoritative: if `VERSION` disagrees, the tag wins and the run logs
a warning. The version reaches each platform from `scripts/version.sh` —
`build_app.sh`'s Info.plist on macOS, `MARKETING_VERSION` on iOS, `-p:Version=`
on Windows.

## What a release contains

| Asset | What it is |
|---|---|
| `Pauselet-<v>.zip` | macOS 13+, Developer ID signed and notarized |
| `Pauselet-<v>-windows-x64.zip` | Windows 10 1809+, self-contained — no .NET to install |
| `Pauselet-<v>-ios-archive.zip` | An unsigned `.xcarchive`, proof the iPhone build is good |

Each platform runs its own suite before building — `swift test`, `dotnet test`
and `PauseletTests` on a simulator — and the release job needs all three, so a
red suite anywhere means no release rather than a partial one.

The iOS archive is deliberately not installable: Apple only allows that through
TestFlight or the App Store. It ships so the iPhone build is never silently
skipped, and so the exact binary and its symbols can be inspected.

### Why the Windows build looks the way it does

It is a **self-contained** publish, so the .NET runtime travels inside the zip
and the app runs on a machine with nothing installed:

```sh
dotnet publish Windows/Pauselet.App/Pauselet.App.csproj \
  --configuration Release --runtime win-x64 --self-contained true \
  -p:Version=1.0.0 -p:DebugType=none --output publish/win-x64
```

That is ~188 MB unpacked, ~75 MB zipped — the price of no runtime
prerequisite. Two options deliberately left off:

- **`PublishSingleFile`** — WPF's native DLLs (`wpfgfx_cor3`,
  `PresentationNative_cor3` and three others) stay loose beside the exe
  regardless, so it is not really one file. It saves about 4 MB of download and
  is the most likely thing to disturb the unpackaged toast COM registration.
- **`PublishTrimmed`** — WPF is not trim-safe, and the app leans on
  reflection-driven XAML and SAPI COM interop. A trimmed build would pass CI
  and crash at launch.

`win-x64` only: Windows on ARM emulates x64, and a second RID would double the
size of every release. Adding `win-arm64` later is one more publish and zip
step.

## One-time signing setup

Notarization matters here for more than Gatekeeper warnings: macOS will not
grant notification authorization to an app it does not fully trust, so an
un-notarized build falls back to the app's own card instead of posting real
system notifications.

The workflow needs five secrets. Gather them into a folder:

| File | What it is |
|---|---|
| `cert.p12` | Developer ID Application certificate, exported from Keychain Access |
| `cert-password.txt` | the password chosen at export, one line |
| `AuthKey_<ID>.p8` | App Store Connect API key — App Store Connect → Users and Access → Integrations → App Store Connect API. The Developer role is enough. |
| `ids.txt` | two lines: `KEY_ID=<the key's ID>` and `ISSUER_ID=<uuid>` |

Then upload them and delete the folder:

```sh
sh scripts/set_github_secrets.sh ~/Desktop/pauselet-signing
rm -rf ~/Desktop/pauselet-signing
```

That sets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_API_KEY_ID`,
`APPLE_API_ISSUER_ID` and `APPLE_API_KEY_P8`. It is all five or none: a signed
but un-notarized app is still blocked by Gatekeeper, so a partial set would
produce a build that claims to be signed and still will not open. With none set
the workflow still runs and produces an ad-hoc signed Mac zip, and the release
notes say so honestly instead of promising notarization.

The certificate expires every few years; renewing it means re-exporting and
re-running the script.

## Signing and notarizing by hand

Still supported, and unchanged apart from `notarize.sh` now taking arguments:

```sh
SIGN_IDENTITY="Developer ID Application: Christian Venter (4R94388LH8)" ./scripts/build_app.sh
ditto -c -k --keepParent dist/Pauselet.app dist/Pauselet-1.0.0.zip
./scripts/notarize.sh dist/Pauselet.app dist/Pauselet-1.0.0.zip
```

This uses the `reminder-notary` keychain profile. If you have not set one up:

```sh
xcrun notarytool store-credentials "reminder-notary" \
  --apple-id "you@example.com" --team-id "4R94388LH8" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

(an app-specific password from <https://appleid.apple.com>). In CI the same
script takes an API key instead, picked up from the environment.

## Testing a change to the workflow

Two ways, neither of which publishes anything:

- **Run it without a tag** — the *Release* workflow has a manual trigger. It
  builds and checks all three platforms and skips the publishing step.
- **Use a throwaway tag** for a full rehearsal including the release itself:

  ```sh
  git tag v0.0.1-test && git push origin v0.0.1-test
  # inspect the release, then tear it down
  gh release delete v0.0.1-test --yes
  git push --delete origin v0.0.1-test
  git tag -d v0.0.1-test
  ```

  Assets come out named `Pauselet-0.0.1-test-*.zip`, so there is no mistaking
  one for real.

## Before the first real release

Download each asset and check it on the real thing:

- **macOS** — unzip, drag to Applications, confirm it opens with no Gatekeeper
  prompt and that notifications are granted.
- **Windows** — unzip and double-click `Pauselet.exe` on a machine with **no**
  .NET Desktop Runtime installed, and confirm toast notifications work. This is
  the least-proven claim in the pipeline: every previous Windows build was
  framework-dependent with the runtime installed machine-wide. `Windows/TESTING.md`
  has the notification matrix.
- **iOS** — the archive should open in Xcode's Organizer.

## Adding TestFlight later

The archive step is built so this is additive rather than a rewrite:

1. Drop the four `CODE_SIGN*` overrides from the archive step.
2. Import an Apple Distribution certificate into a throwaway keychain — the
   same step the macOS job already uses — and either keep automatic signing
   with `-allowProvisioningUpdates` (which the existing API key covers) or
   switch to manual signing with a downloaded profile.
3. Add `-exportArchive` with an `ExportOptions.plist` using
   `method: app-store-connect`, producing a `.ipa`.
4. Upload with `xcrun altool --upload-app`, using the same
   `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID` secrets.

`CURRENT_PROJECT_VERSION` is already the commit count, which satisfies App Store
Connect's requirement that each upload's build number increase.

One thing still outstanding for a real iOS release: the time-sensitive
notification entitlement needs the capability enabled on the App ID
(`docs/BUG_REVIEW_2026-09-08.md`, N2).

## If a run stalls

The iOS job needs the `macos-26` runner for AlarmKit and the iOS 26 SDK. GitHub
retires runner image labels eventually, and a retired label leaves jobs queued
rather than failing. If the iOS job never starts, bump the label in
`.github/workflows/release.yml` (and `ci.yml`) to the current image and re-tag.
