# Windows port — VM setup and test plan

The complete plan for verifying the port in the Windows 11 Parallels VM, in
the order that retires the most risk first. Tick boxes as you go.

> **Status 2026-08-24:** a headless session already drove the VM through much
> of this (see HANDOFF.md → "VM verification session"): toolchain installed,
> 195 tests green in the VM, and the critical overlay, subtle card, toast
> round-trip, tray icon and flyout all verified from screenshots. Items below
> marked ✅ have that evidence; everything else still wants human eyes. Parts
> of setup Part 1 are already done in the VM.

---

## Part 1 — One-time VM setup

### 1.1 Parallels configuration
- [ ] Give the VM **2 CPUs / 8 GB** if it has less (Actions menu → Configure →
      Hardware). .NET builds are comfortably fast at that size.
- [ ] Displays: for the multi-monitor overlay tests you will want **two
      displays**. Two options: put the Mac on an external display and run the
      VM in full screen on both ("Use all displays in full screen"), or test
      single-display first and do the multi-monitor pass later — everything
      else works on one display.
- [ ] Make sure the VM has **sound output** enabled (Configure → Hardware →
      Sound & Camera) — several tests listen for chimes.
- [ ] Snapshot the VM before installing anything ("clean base"), so future
      from-scratch install tests are one revert away.

### 1.2 Toolchain (inside Windows, PowerShell)
```powershell
winget install Microsoft.DotNet.SDK.8
winget install Git.Git
# optional but recommended for editing:
winget install Microsoft.VisualStudioCode
```
Close and reopen the terminal after installing so PATH updates.

- [ ] `dotnet --version` prints an 8.0.x version.

### 1.3 Claude Code (same AI workflow as on the Mac)
```powershell
irm https://claude.ai/install.ps1 | iex
```
- [ ] `claude` starts in the repo directory.

### 1.4 Get the code
Clone inside the VM rather than building over a Parallels shared folder —
.NET builds on network-mapped folders are slow and file-locking gets weird:
```powershell
git clone https://github.com/Crypto69/pauselet.git
cd pauselet
git checkout windows-port
```

### 1.5 Smoke check — proves toolchain + port in one step
```powershell
dotnet test Windows/Pauselet.Core.Tests
```
- [ ] **Expected: 287 passed, 0 failed.** (195 of these were verified in this
      VM on 2026-08-24; the parity work since was verified on macOS only.)
      This runs the complete behavioural
      spec (scheduler, engine, DST, persistence, golden files) on real
      Windows. If this is green, the port's logic is correct on this machine
      and everything after is about the shell.

### 1.6 Run the app
```powershell
dotnet run --project Windows/Pauselet.App -- --open-settings
```
- [ ] App starts, no crash, settings window opens, a tray icon exists in the
      taskbar overflow (click the ^ chevron near the clock).
- [ ] Pin the icon: Settings → Personalization → Taskbar → Other system tray
      icons → Pauselet **On**. (This is the Windows 11 default-hidden
      behaviour the plan calls out — the app cannot pin itself.)

---

## Part 2 — Manual test matrix

Work through in order; the early groups are the platform-risk spikes from the
plan (Phase 0) folded into the real app. For timing tests, create throwaway
reminders with 1-minute intervals.

### Group A — Tray surface
- [ ] Hover the tray icon: tooltip reads "Pauselet — <title> in <countdown>"
      and the countdown updates between hovers (5 s tick).
- [x] ✅ *(headless)* Left-click: flyout opens near the tray showing Next up, the reminder
      list with countdowns, priority dots, schedule summaries.
- [ ] Flyout closes when you click elsewhere (transient, like the Mac
      popover). Esc also closes it.
- [ ] Row actions: the checkmark completes ("I already did that"), the
      checkbox disables/enables, a disabled reminder re-enabled does NOT fire
      instantly.
- [ ] Right-click: menu shows Pause for 30m / 1h / 2h / Pause Indefinitely /
      Settings… / Quit. While paused it shows Resume Reminders instead.
- [ ] Pause indefinitely → tooltip says "paused", flyout header shows Paused;
      Resume → interval reminders restart from now (no backlog burst).
- [ ] Switch Windows between light/dark taskbar (Settings → Personalization →
      Colors) — the tray glyph swaps variants and stays visible.

### Group B — Subtle card
- [x] ✅ *(headless)* Create a Subtle reminder, 1-minute interval. When it fires: a small card
      fades in at the **top-right** of the primary display.
- [ ] **Focus test (the whole point of the tier):** have Notepad focused and
      be typing when the card appears — focus must NOT leave Notepad, no
      keystroke lost, the caret never blinks away.
- [ ] The card self-dismisses after the configured seconds (default 8;
      per-reminder override in the editor wins).
- [ ] Clicking the card's checkmark completes the reminder (interval
      restarts).
- [ ] Queueing: fire two subtle reminders in the same minute — the second card
      appears after the first dismisses, not on top of it.

### Group C — Toasts (Normal / Important)
- [ ] Normal tier fires → silent toast with Done and Snooze buttons. *(Important-tier toast verified headless; Normal not yet)*
- [x] ✅ *(headless — Done click → engine recorded completed)* Toast buttons work **without the app coming to the foreground**
      (background activation): Done completes, Snooze snoozes (check the
      flyout countdown afterwards).
- [ ] Clicking the toast body completes (parity with the Mac's default
      action).
- [ ] Swiping the toast away (dismiss) records a "dismissed" event in
      Settings → History.
- [ ] Important tier fires → toast **stays on screen** until acted on
      (Reminder scenario) and a chime plays.
- [x] ✅ *(headless — attributed "Pauselet")* First-run registration: check the toast's app name/icon reads
      "Pauselet" (the toolkit creates a Start-menu entry on first use).
- [ ] **Fallback ladder:** Settings → System → Notifications → turn Pauselet
      notifications **off**. Fire an Important reminder → the in-app corner
      card appears instead and stays ≥ 60 seconds (sticky minimum). Turn
      notifications back on → the next fire arrives as a toast again, without
      relaunching.
- [ ] **Do Not Disturb:** enable DND, fire Important → observe what happens
      (toast suppressed into notification centre is expected Windows
      behaviour). Note the actual behaviour in this file — it decides whether
      we document it or escalate the fallback.

### Group D — Critical overlay (the gating feature)
- [x] ✅ *(headless)* Critical reminder fires → full-screen dark teal takeover with icon,
      title, message, Snooze and Done, hint line. It covers the **taskbar**.
- [x] ✅ *(headless — ring ticked 4:49→4:09; chime-at-zero not yet heard)* With a countdown (e.g. Tilt Back, 5 min activity): ring fills, M:SS
      counts down, button reads "Finish Early" until 0, a glass chime plays at
      0, label flips to "complete", button reads "Done".
- [ ] **Z-order stress:** before it fires, open Task Manager with
      "Always on top" enabled, and play a YouTube video full screen in a
      browser. The overlay must appear above both — and stay above them for
      minutes (the 2 s re-assertion is doing this; leave it up a while).
- [ ] **Keyboard:** when the overlay appears over your work, try Return
      (= Done) and S (= Snooze) immediately. If Windows refused focus, one
      click on the overlay first, then keys work. Note which of the two you
      observe.
- [ ] **Multi-monitor** (2 displays configured): the overlay covers **both**
      displays fully; acknowledging on either closes both.
- [ ] **Queue + prune (the 1.2.4 headline fix):** two critical reminders due
      in the same minute — second queues behind the first; acknowledging the
      first shows the second. Then: leave a takeover unacknowledged for
      3+ minutes while another critical fires behind it → acknowledging shows
      **nothing** (the stale queue entry is dropped) and History shows it as
      "missed".
- [ ] **Preview:** editor → Preview on a critical reminder. It shows the same
      takeover; pressing Done on the preview does NOT complete the real
      reminder (its countdown in the flyout is unchanged).
- [ ] **Virtual desktops:** put the overlay up, press Win+Ctrl+Right to
      switch desktop. Expected: the overlay reappears on the new desktop
      within ~2 s (the re-pin timer re-shows it). Note actual behaviour.
- [ ] **Monitor hot-plug:** with a takeover up, disconnect/reconnect the
      second display (in Parallels: toggle the display) → the overlay
      re-lays-out to cover the current displays.
- [ ] **Lock screen:** lock (Win+L) while a critical is due; the overlay
      cannot draw there (platform boundary). On unlock, the reminder is
      present/fires promptly (unlock triggers a tick).
- [ ] **Exercise takeover:** an exercise reminder fires → the overlay lists
      each exercise (name, "3 × 10", instructions) with a tick circle each,
      "0 of N done" above the list, Snooze/Done beneath. A long list (8+
      exercises) scrolls without pushing the buttons off-screen; ticking dims
      the row and updates the count; Done works with nothing ticked; nothing
      is remembered on the next fire.
- [ ] **Exercise keyboard:** 1–9 (and the numpad) toggle rows; Tab reaches
      every row then Snooze/Done, Space toggles the focused row; Return still
      completes and S still snoozes even while a row has focus.
- [ ] **Exercise multi-monitor:** ticks are per display (expected — they are
      not mirrored); acknowledging on either display closes both.

### Group E — Sleep, wake, downtime
- [ ] Sleep the VM 10+ minutes past a 1-minute reminder's due time; on wake it
      fires **once** (single catch-up, not a burst).
- [ ] Quit the app; wait 5+ minutes with reminders due; relaunch → **nothing
      fires or appears** (backlog absorbed as missed; check History), and each
      interval restarts from launch.
- [ ] Quit and relaunch within ~1 minute of a due reminder → it still fires
      (downtime grace).

### Group F — Persistence & Mac interchange
- [ ] Data lives at `%APPDATA%\Pauselet\data.json`; open it — pretty-printed
      JSON, same shape as the Mac file.
- [ ] **The migration promise:** copy the real Mac file
      (`~/Library/Application Support/Pauselet/data.json`, e.g. via a
      Parallels shared folder) over the Windows one while the app is closed.
      Launch → every reminder, setting, and history entry appears; icons and
      sounds resolve via the mapping tables.
- [ ] Copy the Windows-written file back to the Mac (to a test location) and
      open the Mac app against it — reminders intact in the other direction.
- [x] ✅ *(headless — a BOM'd file exercised exactly this path)* Corrupt the file (delete a `{`) → app launches with the starter set and
      `data.corrupt.json` preserves the damaged bytes.

### Group G — Settings, editor, system integration
- [ ] CRUD: add / edit / delete reminders; all three schedule kinds
      round-trip through the editor correctly.
- [ ] **Exercise editor:** Type → Exercise hides "How it interrupts" and the
      Subtle on-screen-time field, shows the Critical note, adds one blank
      exercise, and switches the icon to the dumbbell (only if it was still
      the bell). Add / Remove rows; headers renumber. Save refuses: no
      exercises, a blank name, sets or reps of 0 or non-numeric — each with a
      message naming the exercise and focus on the field. Edit → rows reload
      in order; switching back to Standard and saving drops the list, with
      the tier radios showing Critical (what was saved) for you to change.
      Preview shows the exercise takeover.
      The window stops growing at ~90% of the work area and the form scrolls
      with Save still visible.
- [ ] Flyout and Settings rows for an exercise reminder read
      "Every 2 hours · 3 exercises · 9 sets"; the Priority column says
      Critical.
- [ ] Icon picker: `dumbbell.fill` renders as a dumbbell (new
      `fitness_center` glyph in the rebuilt subset font), and the overlay's
      tick circle / check glyphs render.
- [ ] Quiet hours: set a window covering now; non-critical reminders go
      silent, critical still fires (with "allow critical" on); the flyout
      countdown points at the post-window fire, not the suppressed slot.
- [ ] Launch at login: toggle on → entry appears in Task Manager → Startup
      apps; reboot the VM → Pauselet is running. Disable it in Task Manager
      (not in the app) → the settings checkbox shows Off next time (OS state
      is truth).
- [ ] Light/dark app theme switch (Settings → Colors → light/dark mode) —
      flyout and cards re-theme on next open; nothing unreadable. Screenshot
      anything ugly for the polish pass.
- [ ] Sounds: "Listen" in the editor plays each mapped chime. (They are
      synthesized placeholders — judge audibility/pleasantness and note
      replacements needed.)
- [ ] Icon glyphs: eyeball every entry in the editor's icon picker against
      its name — `SymbolMap.cs` codepoints were chosen blind and some will be
      wrong. List the bad ones.
- [ ] Keyboard-only pass: operate flyout, settings, editor, and the critical
      overlay entirely without the mouse (Tab/Space/arrows/Return). This
      app's audience makes this a requirement, not polish.

### Group H — Soak
- [ ] Leave the app running for a half-day with the normal reminder set:
      fires stay on time (±5 s), no memory creep in Task Manager, tooltip
      countdown never goes stale.

### Group I — Exercise parity (added 2026-09-04, never run)

Everything in this group was written on a Mac and has **never been seen
running** — the app compiles for `win-arm64` and the core logic is covered by
287 tests, but no part of this UI has been rendered. Treat it as a first pass,
not a regression check.

**The three new editor fields (Win-1)**
- [ ] Editing an exercise reminder shows Hold, Rest and Set rest beside Sets
      and Reps, with a caption under them.
- [ ] With Hold at 0 both rest fields are greyed out and the caption reads
      "Seconds. Hold 0 leaves this exercise untimed."; typing a hold enables
      them and the caption changes.
- [ ] A blank or out-of-range timing is refused by name on Save, not silently
      read as 0.
- [ ] **Interchange:** a reminder with timings saved on the Mac opens here with
      them intact, and survives a round trip back.

**Import from text (Win-2/Win-3)**
- [ ] "Import from Text…" sits beside Add exercise and opens the dialog.
- [ ] Pasting `3 sets of 10 chin tucks, hold 5 seconds, rest 30 seconds
      between sets` and pressing **Read Text** produces one row, named "Chin
      tucks", 3 × 10, hold 5, set rest 30.
- [ ] The preview rows are editable and Remove drops one; **Add N Exercises**
      appends them and an untouched blank row is replaced, not left above.
- [ ] Cancel adds nothing.
- [ ] Nonsense text shows "No exercises found in that text", not an empty list.

**The coach (Win-4) — the riskiest item here**
- [ ] A guided exercise's takeover row has **Start** and **Skip** pills, and
      the suggested row's Start is the filled one.
- [ ] Start shows the panel: countdown ring, "Set 1 · Rep 1", "Hold", and
      Pause/Skip/Stop. The ring drains over the phase.
- [ ] **Space** starts or pauses, **N** skips a phase, **X** stops. Pause
      shows "Resume" and freezes the count.
- [ ] With the voice on, each phase is *announced before it is timed* — "Hold
      for 5 seconds" finishes, and only then do five seconds run.
- [ ] Holds of 6 s or more get a spoken "Three. Two. One."
- [ ] Finishing an exercise ticks its box and plays the completion chime; the
      suggestion moves to the next guided exercise.
- [ ] **Lock the PC mid-hold** (Win+L): on return the session is paused, not
      advanced. Same for sleep/resume.
- [ ] Multi-monitor: a cue is spoken **once**, and a tick shows on every
      display.
- [ ] Voice Coach settings: the voice picker lists English SAPI voices, Test
      speaks a sample cue, and the pace slider changes the speed audibly.
      (If no English voice is installed the section says so.)

**AI import (Win-5)**
- [ ] With no key stored, the import dialog shows **no** "Interpret with AI"
      button and the app makes no network requests.
- [ ] Saving a key in Preferences → Exercise Import clears the box and reports
      that a key is stored; **Test** reports whether it works.
- [ ] With a key, "Interpret with AI" fills the preview rows; a bad key
      reports "That API key was rejected", and pulling the network reports the
      offline message — **not** a crash, and the local parse stays on screen.
- [ ] **The key is not in `data.json`.** Open `%APPDATA%\Pauselet\data.json`
      and grep for it; it must be absent. It lives encrypted in `secrets.dat`.
- [ ] Remove takes the key away and the AI button disappears again.

**History (Win-6)**
- [ ] The History tab has a 24 hours / 7 days / 30 days picker, defaulting to
      7 days, and switching it re-filters the log.
- [ ] An "Adherence" list shows one bar and percentage per reminder that fired
      in the window; reminders with nothing in the window are absent, not 0 %.
- [ ] A window with no activity shows "No activity in this period" rather than
      an empty table.

**Catalog and icons (Win-7)**
- [ ] The interval schedule offers the preset list (5 min … 4 hours) and
      choosing one fills the minutes box; a custom number still typeable.
- [ ] The icon picker's first twenty icons all render as real glyphs — in
      particular the four new ones: **eye, raised hand, medical case, wind**.
      A bell where one of those should be means a missing codepoint.

---

## Part 3 — When things fail

- Logic/timing wrong → it is almost certainly shell wiring
  (`Program.cs` / `OverlayPresenter.cs`), because the same logic passes 287
  tests; fix the shell, not the core.
- A behaviour genuinely missing from the core → write the failing xUnit test
  first (the Swift suite is the reference), then fix.
- Overlay z-order / focus / DPI issues → `CriticalOverlayWindow.cs`
  (`PinToBounds`, the re-assert timer) — these are the known platform sharp
  edges the design already defends against; tune there.
- Anything visual → screenshot it and iterate in the VM with Claude Code; the
  UI is all code-built (no XAML), one file per surface.

## Part 4 — After the VM pass
1. Fix what Part 2 surfaced; keep `dotnet test` green.
2. Commit from the VM (or from the Mac) to `windows-port`; push → the
   `windows-latest` CI job re-verifies on a clean machine.
3. Then Phase 4 of the plan: MSIX packaging + Store registration — on real
   hardware, not the VM.
