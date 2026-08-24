# Windows port — implementation status

*Written 2026-08-24, on branch `windows-port`. Companion to the (untracked)
"Windows Conversion Plan.md" at the repo root and to `TESTING.md` beside this
file.*

Everything here was developed and compiled **on the Mac** (`dotnet` builds and
runs the core tests on macOS; the WPF shell cross-compiles via
`EnableWindowsTargeting` but cannot run). Nothing has executed on Windows yet
— that is what `TESTING.md` is for.

## What is done

### Phase 1 — Core port: complete and verified
- `Pauselet.Core` is a faithful C#/.NET 8 translation of `ReminderCore`
  (Models, Scheduler, Store, Engine, Projection, Music). NodaTime carries the
  calendar math; CommunityToolkit.Mvvm's `ObservableObject` stands in for
  Combine.
- **168 xUnit tests pass** (`dotnet test Windows/Pauselet.Core.Tests`): the
  entire Swift suite translated 1:1 (minus the two Mac-only legacy-directory
  migration tests), plus new golden-file tests.
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
2. **SF → Segoe Fluent glyph mapping** (`SymbolMap.cs`) — codepoints are
   best-effort; review each rendered glyph, especially the figure/exercise
   ones. Unmapped names fall back to the bell.
3. **Flyout positioning** assumes a bottom-docked taskbar; check against
   top/side docking.
4. **First toast registration**: the Toolkit auto-creates a Start-menu
   shortcut/AUMID on first `Show` for unpackaged apps — verify the app name it
   shows and that buttons activate the running process.
5. UI polish generally: paddings, dark/light theming of the settings tabs,
   and the editor's layout were written blind and will need pixel adjustments.

## Working on this from Windows
See `TESTING.md` for VM setup and the full manual test matrix. Short version:

```powershell
winget install Microsoft.DotNet.SDK.8 Git.Git
git clone https://github.com/Crypto69/pauselet.git && cd pauselet
git checkout windows-port
dotnet test Windows/Pauselet.Core.Tests   # expect 168 green
dotnet run --project Windows/Pauselet.App -- --open-settings
```
