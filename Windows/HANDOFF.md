# Windows port — implementation status

*Written 2026-08-24, on branch `windows-port`. Companion to the (untracked)
"Windows Conversion Plan.md" at the repo root and to `TESTING.md` beside this
file.*

Everything here was developed and compiled **on the Mac** (`dotnet` builds and
runs the core tests on macOS; the WPF shell cross-compiles via
`EnableWindowsTargeting`). It has since been exercised on real Windows three
ways: the CI job on `windows-latest`, and a headless session driving the
actual Parallels Windows 11 VM over `prlctl` — see "VM verification session"
below. The human pass in `TESTING.md` is still wanted, but the platform-risk
questions are substantially answered.

## What is done

### Phase 1 — Core port: complete and verified
- `Pauselet.Core` is a faithful C#/.NET 8 translation of `ReminderCore`
  (Models, Scheduler, Store, Engine, Projection, Music). NodaTime carries the
  calendar math; CommunityToolkit.Mvvm's `ObservableObject` stands in for
  Combine.
- **195 xUnit tests pass** (`dotnet test Windows/Pauselet.Core.Tests`): the
  entire Swift suite translated 1:1 (minus the two Mac-only legacy-directory
  migration tests), plus new golden-file tests and the exercise-list tests
  (`ExerciseTests`, whose inline fixture is the Swift encoder's output).
- **One firing decision, same as the Mac**: `Scheduler.NextStep` is what
  `Tick()`, `Projection.ProjectedFires`, `IsDue` and `RefreshNextUp` are all
  defined through (the Swift `nextStep` refactor of 2026-09-02, ported the
  same day). `AdvanceStepTests` runs the live engine against the projection
  for three simulated days and pins the timed-pause and quiet-hours cases
  that used to drift. External fires are batched (`RecordExternalFires`)
  and dated at delivery, as on the Mac.
- **Byte-compatible persistence is proven, not aspirational**: the fixtures in
  `Pauselet.Core.Tests/Fixtures/` were written by the real Swift encoder on
  macOS, and the tests decode them and re-encode them byte-for-byte
  (`GoldenFileTests`). A `data.json` can be copied Mac → PC and back.
  One documented asymmetry: multi-weekday sets are written in Swift hash order
  by the Mac and always sorted ascending here; both sides read either.
- CI: `.github/workflows/windows.yml` runs the suite and builds the solution
  on `windows-latest` for every push touching `Windows/`.

### Phase 2/3 — Shell and UI: written, compiles, unverified
`Pauselet.App` (WPF, `net8.0-windows10.0.19041.0`, runs down to Win10 1809):

- **Tick loop** (`Program.cs`): 5 s `DispatcherTimer`, `PowerModeChanged`
  (resume) and `SessionSwitch` (unlock) → immediate tick,
  `AbsorbBacklogFromDowntime()` before the first tick, single-instance mutex,
  persist on exit.
- **Tray** (`TrayController.cs`, H.NotifyIcon): tooltip countdown (the
  stand-in for the Mac menu-bar text), left-click flyout, right-click quick
  menu (pause 30m/1h/2h/indefinitely, resume, Settings, Quit), light/dark
  taskbar glyph variants.
- **Presenter** (`OverlayPresenter.cs`): the same routing and queue semantics
  as the Mac `OverlayPresenter` — critical queue with
  `ShouldPresentQueued` pruning and missed-recording, subtle queue, preview
  that replaces and never mutates, `DismissAll` on pause.
- **Critical overlay** (`CriticalOverlayWindow.cs`): one borderless topmost
  window per monitor at physical pixel bounds (PerMonitorV2 manifest), 2 s
  topmost re-assertion + re-pin, `WM_DISPLAYCHANGE` → re-layout (better than
  the Mac app, which has no hot-plug handling), Return/S shortcuts, polite
  activation attempt, dark teal gradient + countdown ring + Snooze /
  Done / Finish Early — a direct recreation of `CriticalOverlayView`.
- **Subtle card** (`SubtleCardWindow.cs`): `WS_EX_NOACTIVATE` corner card,
  fade in/out, per-reminder display seconds, sticky minimum for fallback use.
- **Toasts** (`ToastPresenter.cs`): Done/Snooze buttons with background
  activation, `scenario=Reminder` for Important, out-of-band sound, and the
  full fallback ladder — availability tracking, error fallback, toast-dismiss
  → `Dismiss()`, unavailable → in-app card with 60 s sticky minimum for
  Important+.
- **Settings window**: Reminders / Preferences / History / About tabs;
  reminder editor with all schedule kinds, tier picker, icon picker, sound
  picker, on-screen time, activity countdown, Preview. Preference edits apply
  immediately.
- **Launch at login** (`LaunchAtLogin.cs`): HKCU Run key, OS-state-is-truth.
- **Assets** (`scripts/build_assets.py`): app icon and tray icons generated
  from the repo's existing masters; six synthesized chime .wavs with a
  name-mapping table from the 14 macOS sound names.

## Deliberately not ported (per the plan)
- Spotify/music playback (v2; all music data fields persist untouched).
- Menu-bar countdown *text* (tooltip + flyout carry it; a drawn-icon countdown
  is a possible later setting).
- Snapshot harness, `x-apple.systempreferences` deep links (→ `ms-settings:`
  when we add guidance links).
- Mac legacy-directory migration (no Windows install has ever existed).

## Known placeholders needing a human pass in the VM
1. **Sounds are synthesized placeholders** — replace with designed CC0
   recordings before release; only the mapping table needs updating.
2. ~~SF → Segoe Fluent glyph mapping~~ **Resolved 2026-08-25**: the icons now
   come from a bundled 9 KB subset of Material Symbols (Apache 2.0), which
   actually has the human-figure poses — `figure.seated.side` renders as a
   person reclining. `SymbolMap.cs` carries the audited codepoint table; a
   quick visual pass over the picker in the VM is still worthwhile.
3. **Flyout positioning** assumes a bottom-docked taskbar; check against
   top/side docking.
4. **First toast registration**: the Toolkit auto-creates a Start-menu
   shortcut/AUMID on first `Show` for unpackaged apps — verify the app name it
   shows and that buttons activate the running process.
5. UI polish generally: paddings, dark/light theming of the settings tabs,
   and the editor's layout were written blind and will need pixel adjustments.
6. **Exercise reminders** (editor rows, the overlay's exercise list and
   tick rows, the flyout/Settings summary) were written blind on the Mac —
   see the new items in TESTING.md Groups D and G. The model and JSON side
   is covered by `ExerciseTests` and verified against the Swift encoder's
   bytes.

## VM verification session (2026-08-24, headless via prlctl)

Ran in the actual Parallels Windows 11 (ARM64) VM, driving it from the Mac
with `prlctl exec` and verifying visually from `prlctl capture` screenshots
(kept in the session records; the artifact page shows the highlights).

**Verified working:**
- All **195 core tests pass in the VM** (`dotnet test`), as on macOS and CI.
- App startup end-to-end: engine load → toast registration → tray icon →
  backlog absorption → tick loop. Fire timing exact (a reminder due at
  seed+10 s fired at seed+11 s).
- **Critical overlay**: full-screen takeover that dims the desktop, covers
  the taskbar, countdown ring ticking (4:49 → 4:09 across 40 s), Snooze /
  Finish Early buttons; clicking Finish Early completed the reminder and
  re-anchored the interval.
- **Subtle card**: appeared top-right on schedule, dark-themed to match the
  VM, correct glyph, checkmark button.
- **Important toast**: attributed to "Pauselet" (unpackaged registration
  worked), Done/Snooze buttons present; clicking **Done** activated the
  background COM path → engine recorded `completed` and persisted. Toast
  dismissal wiring in place.
- **Tray + flyout**: icon present in the overflow; flyout showed "Next up ·
  Weight Shift · 28 min", reminder rows with countdown/dot/summary/toggle,
  Settings/Quit footer. The flyout's close-on-deactivate behaviour works
  (it closed the moment another process took focus).
- **Corrupt-file recovery**: a bad data.json produced `data.corrupt.json`
  and a clean starter-set launch, exactly as designed.

**Found and fixed:**
- `AppDataJson.Decode` now tolerates a UTF-8 BOM (test #169). A BOM'd but
  otherwise valid file — trivially produced by Windows tools — previously
  went down the corrupt-file path and replaced the user's reminders with the
  starter set.

**Recorded for the human pass:**
- Overlay keyboard shortcuts: with the app launched *by a background
  process*, Windows refused focus and Return did nothing until a click —
  the documented platform ceiling, and the click-first path works. Worth
  re-testing from a normal user launch, which may well be granted focus.
- `figure.seated.side` renders as a wrong (game-controller-ish) glyph —
  first confirmed instance of the SymbolMap review the plan expects.

**VM state left behind:** .NET 8 SDK at `C:\dotnet`, the .NET Desktop
Runtime installed machine-wide (so `Pauselet.exe` runs by double-click), and
a source snapshot at `C:\work\pauselet-windows-port` with the app built at
`Windows\Pauselet.App\bin\Debug\net8.0-windows10.0.19041.0\Pauselet.exe`.
For ongoing work, replace the snapshot with a real `git clone` (TESTING.md
step 4). The app's data directory was cleaned, so the next launch is a fresh
first run. The VM was left running.

## Working on this from Windows
See `TESTING.md` for VM setup and the full manual test matrix. Short version:

```powershell
winget install Microsoft.DotNet.SDK.8 Git.Git
git clone https://github.com/Crypto69/pauselet.git && cd pauselet
git checkout windows-port
dotnet test Windows/Pauselet.Core.Tests   # expect 195 green
dotnet run --project Windows/Pauselet.App -- --open-settings
```
