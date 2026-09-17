# Bug review — macOS, iOS and Windows

**Date:** 2026-09-08
**Scope:** the whole codebase on `main`, including the uncommitted exercise-coach work (Start All, rest between exercises, cancel mid-run, reorder in editors). Three trees: the Swift package (`Sources/ReminderCore`, `ReminderAI`, `ReminderUI`, `ReminderApp`), the iOS app (`iOS/`), and the Windows port (`Windows/Pauselet.Core`, `Windows/Pauselet.App`).
**Method:** `/code-review high` on the working-tree diff (eight finder agents plus two adversarial verifiers), then five whole-application bug hunts, one per tree, with every claim traced through the code. Findings below are the ones that survived verification; cleanups that were only duplication or style were dropped unless they are the direct cause of a listed bug.
**Baseline before any fix:** `swift test` 282 green, iOS simulator suite 327 green, `dotnet test Windows/Pauselet.Core.Tests` 294 green.

Status marks: `[ ]` open · `[x]` fixed and covered by a test where one is practical.

---

**Resolution (2026-09-08, same day):** every item below except N2 is fixed; N2 was closed on 2026-09-17 as a deliberate won't-fix, since the entitlement it needs is not available to a Developer ID build — see its entry. Test counts after the fixes: `swift test` **300** (was 282), iOS simulator **345** (was 327), `dotnet test Windows/Pauselet.Core.Tests` **317** (was 294); `swift build` and `dotnet build Windows/Pauselet.App -r win-arm64` both succeed. Where the fix differs from the one suggested:

- **W3 (welded after sleep):** the edge-case suite pins that every reminder overdue after a sleep fires on that first tick, critical last, so nothing is deferred. Instead the lapsed fires are stamped a short way *back* from the tick, spread `staggerStep` apart (capped so none is due again at once) with the most overdue getting the oldest stamp, so the next round comes back spaced and in order.
- **C4 (cancel mid-run):** rather than skipping cancelled entries at run time, the coach rebuilds the run. Cancelling a queued exercise rebuilds the timeline without it and carries the cursor and state across (paused stays paused; an announcement in flight is still released by its own callback, since every phase before the cursor is unchanged). Cancelling the one being coached hands over to what follows it, from that exercise's lead-in, with no sign-off for the cancelled one; when nothing follows, a run of several completes (the behaviour an existing test pins) and a lone exercise stops. `cancel` refreshes `now` from the clock first. Four new iOS coach tests cover the queued cancel, a queued-then-active cancel, a cancel while paused, and the clock-vs-tick judgement.
- **W9:** Cancel is shown on the active row on all three platforms; the Start pill is hidden there already, so the pill takes its slot.
- **W24 / IN2:** every announcement carries a generation; the speech callback and the 8 s fallback both check it, and `run`/`stop`/`shutDown` cancel the fallback task and bump the generation. Windows already stopped its fallback timer.
- **W1:** `Reminder.applyingEdits(from:)` and `ReminderEngine.applyEdits(_:)` (C# `ApplyingEdits`/`ApplyEdits`) keep `isEnabled`, `createdAt` and the three engine stamps; the three editors' Save paths use them. `update(_:)` is unchanged.
- **W8:** delivery policy is untouched; the three editors show a "Falls inside quiet hours (22:00–07:00), so it will be skipped" caption under a daily or weekly time, driven by `Scheduler.wallClockTimeIsSilenced` / `QuietHours.covers`.
- **W12:** a shared `ActivityCountdown` (one per takeover, owned by the presenter, wall-clock driven, one chime) replaces the per-view state; **W14** rebuilds the panels around it and the coach on `didChangeScreenParametersNotification`.
- **C5:** an unsolicited close (Alt+F4, taskbar) is cancelled and answered as Snooze on the next dispatcher turn; the presenter's own `CloseOverlay` sets a flag that lets the close through; timers and the coach subscription end in `OnClosed`. **W19** re-pins on `OnDpiChanged`.
- **IC1 / IW1:** `foldInExternalState()` (delivered fires, alarm registry, backlog) now precedes any mutation in the notification-response and alarm-stop handlers and on a significant time change. The hand-off copy's request identifier is remembered, removed when the takeover is answered in-app, and a dismiss of that copy while the takeover is still up is a no-op.
- **N3:** the notifier's centre is `nil` outside a bundle and the presenter reports notifications unavailable, so `swift run` falls back to the in-app card instead of crashing.
- **N12:** ported the starter-set, voice-coach settings and missing-fields cases; the golden file was not regenerated (it would need the Mac encoder run against a fixture with exercise and voice keys — noted for whoever next touches the fixtures).
- **N2:** not changed here — adding the time-sensitive entitlement needs the capability on the App ID; left as a release-checklist item.

**Not verified live:** the Windows UI changes (C5, C6, W10, W11, W15–W20, N13–N16) compile but, as with the rest of the Windows shell, have not been run in the VM; the Mac display-change relayout (W14) and the shared countdown (W12) were exercised through the snapshot harness and the build only.

---

## Critical

Data loss, a crash, a reminder that never shows or shows at the wrong time, or the coach walking someone through an exercise they said they cannot do.

### C1. Resuming after a pause pushes any reminder anchored *during* the pause hours late — all platforms (core)
- [x] `Sources/ReminderCore/Scheduler.swift:281` `reanchorForDowntime` shifts a mid-interval anchor by the whole downtime length, even when the anchor itself was set inside the downtime. Windows twin: `Windows/Pauselet.Core/Scheduler.cs` `ReanchorForDowntime`.
- Hourly reminder, indefinite pause from 09:00 day 1, app relaunched 14:00 day 2 (the launch backlog re-anchors it to 14:00), Resume at 15:00: anchor becomes 14:00 + 30 h, next fire 21:00 on day 3. A reminder added at 10:30 during a pause begun at 10:00 and resumed at 11:00 fires at 11:50 instead of ~11:20.
- Fix: measure the shift from `max(downtimeStart, anchor)`. Also see W2, which is what feeds this case.

### C2. Imported or AI-supplied set and rep counts are unbounded — all platforms (core)
- [x] `Sources/ReminderCore/Exercise.swift:118` `normalized` clamps hold and rests but not `sets`/`reps`; `summary(of:)` sums sets with a trapping `+`; `ExerciseTimeline` builds `sets × reps` phases. Windows twin: `Windows/Pauselet.Core/Exercise.cs`.
- Paste "Squats 3 sets of 99999999999 reps" and press Start: the timeline tries to build 3 × 10¹¹ phases. A JSON row with `sets = Int.max` plus a second exercise traps in the list row's summary.
- Fix: `setsRange` 1…20 and `repsRange` 1…100 in the core (the values the editors already use), clamped in `normalized` on both cores.

### C3. A huge number in the OpenAI reply crashes the app — macOS and iOS
- [x] `Sources/ReminderAI/ExerciseInterpreter.swift:296` `integer(_:)` does `Int(number)` on a `Double`, which traps outside `Int`'s range. Reproduced with `{"sets": 1e23}`.
- Fix: range-check the double before converting; C2's clamp then bounds the value.

### C4. Cancelling a queued exercise during Start All still coaches it — all platforms
- [x] `Sources/ReminderApp/ExerciseCoach.swift:196`, `iOS/PauseletiOS/ExerciseCoach.swift:187`, `Windows/Pauselet.App/ExerciseCoach.cs:232`. `cancel` only records the id; the timeline built up front still contains the exercise, so when its turn comes the coach announces it, runs every set, and the row flips to Active over its cancelled state. Two related defects from the same root: cancelling the *active* exercise jumps to the next entry even when that entry was cancelled too, and the next lead-in still says "*Cancelled one* complete." because the sign-off is baked into the cue at build time.
- Also: `cancel` judges "active" against the `now` of the last tick, up to 200 ms stale, so a cancel just after a phase boundary can be judged against the previous exercise.
- Fix: on any cancel of an exercise that is still ahead of the cursor, rebuild the session from the current timeline minus that exercise, mapping the cursor across (same offset when the dropped exercise is later; the next exercise's lead-in when it is the active one), preserving paused/announcing state. Refresh `now` from the clock first.

### C5. Alt+F4 on the Windows takeover leaves the presenter believing it is still up — Windows
- [x] `Windows/Pauselet.App/CriticalOverlayWindow.cs` has no `OnClosing`; the borderless window still honours SC_CLOSE. `Window.Close` runs without `CloseOverlay`, so the topmost timer keeps re-pinning a dead HWND, the coach subscription leaks, and `OverlayPresenter._criticalWindows` still holds the window. Every later critical reminder is queued behind it and never shown.
- Fix: override `OnClosing` — an unacknowledged close is routed through Snooze (the safe acknowledgement) so the presenter always learns the window went away; stop timers and unsubscribe in `OnClosed`.

### C6. A failing speech synthesizer aborts the whole exercise takeover — Windows
- [x] `Windows/Pauselet.App/OverlayPresenter.cs:284` `BuildCoach` constructs `SpeechCoach`, whose constructor calls `SetOutputToDefaultAudioDevice()`, with no guard. With no audio endpoint (docking station unplugged, RDP) the exception escapes `Engine.Tick` after `LastFiredAt` is stamped: the reminder is recorded as fired and never shown, and this repeats for every exercise reminder until the voice is switched off.
- Fix: catch in `BuildCoach` and degrade to a silent coach; make `VoiceCatalog.Enumerate` catch every exception too (N-W6).

---

## Warning

Visible wrong behaviour in a real but narrower situation.

### W1. Saving the editor clobbers stamps the engine set while it was open — all platforms
- [x] `Sources/ReminderApp/ReminderEditor.swift:401`, `iOS/PauseletiOS/Views/ReminderEditorView.swift:397`, `Windows/Pauselet.App/ReminderEditorWindow.cs:567`. Each editor composes its result from the reminder snapshot taken when it opened, so `lastFiredAt`, `snoozedUntil` and `lastAcknowledgedAt` written by a tick or a banner action while editing are overwritten on Save and the reminder fires again on the next tick (a second `.fired` history event too).
- Fix: a core `Reminder.applyingEdits(from:)` that copies the editable fields onto the engine's current copy; the three save paths use it. `update(_:)` itself keeps accepting stamps — a core test relies on it.

### W2. The launch backlog absorber runs while the engine is paused — all platforms (core)
- [x] `Sources/ReminderCore/ReminderEngine.swift:215` `absorbBacklogFromDowntime` ignores the pause state: on relaunch while paused it records `.missed` for reminders that could not have fired and moves their anchors inside the pause, which C1 then double-counts on Resume.
- Fix: return early (after clearing stale snoozes) when `Scheduler.isPaused`.

### W3. Waking from sleep welds staggered interval reminders together — macOS
- [x] `Sources/ReminderCore/ReminderEngine.swift:407` `tick()` stamps every overdue interval reminder with the same `current`. The Mac app calls `tick()` on wake, not the absorber, so three reminders anchored 09:00/09:20/09:40 that all come due during a 09:50–17:00 sleep fire together at 17:00 and stay welded. (iOS reconciles then absorbs; Windows absorbs before the first tick after resume — check while fixing.)
- Fix: when more than one interval reminder is overdue by more than the downtime grace, re-anchor through `reanchorAllForDowntime` before firing, so the stagger survives.

### W4. The countdown drifts during a timed pause — all platforms (core)
- [x] `Sources/ReminderCore/Scheduler.swift:415` `nextStep` simulates the pause's re-anchor from `now` instead of `settings.pausedAt`, so the projection changes as the pause progresses and disagrees with the engine at expiry (hourly anchored 09:50, paused 10:00–12:00: 12:50 projected at 10:00, 13:00 at 11:00). An iOS foreground pass mid-pause schedules the notification late.
- Fix: `downtimeStart: min(now, settings.pausedAt ?? now)`.

### W5. Pausing again while already paused forgets when the pause began — all platforms (core)
- [x] `Sources/ReminderCore/ReminderEngine.swift:577` `setPaused(true)` and `pause(forMinutes:)` overwrite `pausedAt`. Pause indefinitely at 10:00, then "pause for 30 min" at 11:00: the phase preserved at resume is measured from 11:00.
- Fix: `pausedAt = pausedAt ?? now`.

### W6. A snooze across midnight drags an "every N days" grid out of phase — all platforms (core)
- [x] `Sources/ReminderCore/Scheduler.swift:432` stamps a snoozed wall-clock fire at the delivery moment. Daily-at 23:50 every 2 days, snoozed 15 min, delivered 00:05: next fire is 24 h later instead of 48 h.
- Fix: stamp the slot for wall-clock schedules on the snoozed branch too.

### W7. Importer mis-parses common physio phrasings — all platforms (core)
- [x] `Sources/ReminderCore/ExerciseImporter.swift` and `Windows/Pauselet.Core/ExerciseImporter.cs`, reproduced on the Swift side:
  - "Plank: 3 sets of 30 seconds" → 30 reps, no hold (`setsOfRepsPattern`, `crossPattern` swallow the unit).
  - "Bridges 3 sets of 10 with 30 seconds rest between sets" → rest 0, phrase left in the name (rest verb only accepted before the number).
  - "Hold this position for 10 seconds" → hold lost (`holdPattern` allows only it/for/each).
  - "3 sets of 10 times for 5 seconds glute squeeze" → sets lost (a `times for` match skips `setsOnlyPattern`).
  - "Hold 5 more seconds" → 300 s and the name becomes "Ore seconds" (bare `s`/`m` units with no word boundary).
- Fix: timed-set form first; accept the rest verb after the unit; widen the hold connectives; still read a standalone set count after `times for`; `\b` after the unit. Port each to C# with the same test cases.

### W8. A wall-clock reminder whose slot is always inside quiet hours is silently never delivered — all platforms (core)
- [x] `Sources/ReminderCore/Scheduler.swift:439` daily-at 06:00 with quiet hours 22:00–07:00: every step is `.skip`, `projectedFires` is empty, `nextUp` is nil, and a `.missed` event is recorded every morning.
- Fix: surface it — the editor warns when the chosen time falls inside quiet hours for that priority. Delivery policy stays as designed.

### W9. Cancel is unreachable for the exercise being coached — all platforms
- [x] `Sources/ReminderUI/ExerciseOverlayRow.swift:77` hides Cancel for `.active`; Windows `UpdateCoachRow` likewise. The README and the `cancel` doc comment promise "cancelling the exercise being coached moves straight on to the next", but only tests reach that branch; the panel's Skip advances one phase and Stop abandons the run.
- Fix: show Cancel on the active row (the Start pill is already hidden there, so it fits in the same slot) on all three platforms.

### W10. The Windows A key restarts a run in progress — Windows
- [x] `Windows/Pauselet.App/CriticalOverlayWindow.cs:268` handles A whenever a coach exists. The Mac binds "a" only to the visible Start All button (no session, or completed). Mid-run, A discards the session and restarts from the lead-in.
- Fix: same visibility rule as the button.

### W11. Rest between exercises is validated and saved for a hidden field — all platforms
- [x] `Windows/Pauselet.App/ReminderEditorWindow.cs:868` validates the field even when its panel is collapsed (fewer than two rows), then focuses a collapsed control; a stale "abc" or 700 blocks Save with no way to fix it. Mac and iOS (`ReminderEditor.swift:415`, `ReminderEditorView.swift:414`) silently persist the hidden value for a single-exercise reminder.
- Fix: the rest is nil unless the saved list has two or more exercises, on all three; Windows skips validation for the hidden field.

### W12. The activity countdown stops while the coach runs, and chimes once per display — macOS
- [x] `Sources/ReminderApp/OverlayViews.swift:154` creates the 1 s `Timer.publish` inline in `body`, so every re-evaluation re-subscribes; with a coach session live `coach.now` republishes every 0.2 s and the countdown never ticks. Each display's view also has its own `@State remaining` and plays the Glass chime independently.
- Fix: one shared countdown object per takeover (owned by the presenter), one chime.

### W13. Queued reminders restart the playlist before they are shown — macOS
- [x] `Sources/ReminderApp/OverlayWindow.swift:99` `present` starts music before checking whether the surface is occupied. Critical B arriving behind critical A restarts A's playlist from the top and is later shown silent.
- Fix: start music at the point the reminder is actually displayed.

### W14. Critical panels are never reconciled on display changes — macOS
- [x] `Sources/ReminderApp/OverlayWindow.swift:196` panels are created once from `NSScreen.screens`. Unplug a display mid-takeover and AppKit relocates the orphaned panel onto the built-in screen at the wrong size; plug one in and it is uncovered.
- Fix: observe `didChangeScreenParametersNotification` and rebuild the panel set around the existing coach.

### W15. Pausing the engine closes the Windows takeover but leaves the coach speaking — Windows
- [x] `Windows/Pauselet.App/OverlayPresenter.cs:77` `DismissAll` closes the windows without `ShutDownCoach`. Start All, then "Pause for 30m" from the tray: cues and chimes continue with nothing on screen; the next takeover replaces the coach without disposing the synthesizer.
- Fix: shut the coach down in `CloseCriticalWindows`; relayout is the one path that keeps it.

### W16. Clicking the tray icon cannot close the flyout — Windows
- [x] `Windows/Pauselet.App/TrayController.cs:105` the taskbar takes foreground on mouse-down, the flyout's Deactivated handler closes it, then mouse-up toggles it open again.
- Fix: ignore a tray click that lands within a short window of a deactivation close.

### W17. The flyout rebuilds its whole tree every second — Windows
- [x] `Windows/Pauselet.App/FlyoutWindow.cs:66` the ticker calls `Rebuild()`, so the list's scroll position resets every second and a click that straddles a tick is lost.
- Fix: update the countdown text blocks in place; rebuild only when the reminder set changes.

### W18. Startup has no exception guard — Windows
- [x] `Windows/Pauselet.App/Program.cs:96` if `notifier.Configure()` throws (COM/registry denied), the dispatcher handler swallows it and the process lingers with no tray icon, no ticks and the single-instance mutex held, so relaunching exits immediately.
- Fix: toasts degrade to unavailable; anything else fatal shuts down cleanly.

### W19. A window moved to a monitor with a different DPI is resized by WPF — Windows
- [x] `Windows/Pauselet.App/CriticalOverlayWindow.cs:199` after `SetWindowPos`, WM_DPICHANGED re-applies a scaled rect, so for up to 2 s the takeover covers a quarter of the external display.
- Fix: handle WM_DPICHANGED and re-pin immediately.

### W20. A completed row offers "Again" but 1–9 ignores it — Windows
- [x] `Windows/Pauselet.App/CriticalOverlayWindow.cs:286` `StartExerciseRow` allows Idle/Suggested/Cancelled only; the pill on a completed row says Again.
- Fix: keyboard follows the pill.

### W21. The Windows scheduler resolves a DST-gap time differently from the Mac — Windows
- [x] `Windows/Pauselet.Core/Scheduler.cs:28` `AtLeniently` shifts a skipped wall-clock time forward by the gap length; Apple returns the first instant after the gap. Daily at 02:30 on spring-forward day: Mac 03:00, Windows 03:30; quiet-hour ends inherit the same offset.
- Fix: a resolver that maps a gap to its end instant.

### W22. Windows reminder equality ignores the rest between exercises — Windows
- [x] `Windows/Pauselet.Core/Models.cs:241` `Reminder.Equals` omits `RestBetweenExercisesSeconds`, so a store round-trip test could not notice the field being dropped, and the Swift `testRestBetweenExercisesIsStoredOnlyWhenSet` has no C# port.
- Fix: compare it; port the test.

### W23. Voice Coach help text describes a rule the app no longer follows — all platforms
- [x] `Sources/ReminderApp/VoiceCoachSettings.swift:26`, `iOS/PauseletiOS/Views/VoiceCoachSettings.swift:30`, `Windows/Pauselet.App/SettingsWindow.cs:614` still say "Only exercises with a hold time are coached; the others keep their tick box." Every exercise is coached now and there is no tick box.
- Fix: drop the sentence; tidy the stale "tick box" comments in `Exercise.swift`.

### W24. The 8 s announcement fallback outlives the session it was started for — macOS and iOS
- [x] `Sources/ReminderApp/ExerciseCoach.swift:334`, `iOS/PauseletiOS/ExerciseCoach.swift:312`. The fallback `Task` is never cancelled by `stop()`/`run()`, and it identifies the phase by value, so a restarted session for the same exercise has an equal first phase and a stale fallback can release the new announcement while the cue is still being spoken. Windows already stops its fallback timer.
- Fix: keep the task handle; cancel it on stop, run and shut down.

---

## Nice to have

Robustness gaps and inconsistencies that a user is unlikely to hit today.

### N1. Notification dismissals are never recorded — macOS
- [x] `Sources/ReminderApp/NotificationPresenter.swift:105` the category is registered with `options: []`, so `UNNotificationDismissActionIdentifier` is never delivered and the `.dismissed` branch is dead; History never shows dismissals.
- Fix: `.customDismissAction`.

### N2. Important reminders claim `.timeSensitive` without the entitlement — macOS
- [x] `Sources/ReminderApp/NotificationPresenter.swift:148` the bundle is signed without `com.apple.developer.usernotifications.time-sensitive`, so a Focus mode swallows them and delivery confirmation still reports them landed.
- **Closed 2026-09-17 as won't-fix, deliberately.** The original fix — add the entitlement, having enabled the capability on the App ID — is not available here: Apple grants `com.apple.developer.usernotifications.time-sensitive` for App Store distribution, and the Mac app ships as a Developer ID download (`scripts/build_app.sh`). A Developer ID build can carry the request, but without a profile authorising it the entitlement is not honoured, and adding an unauthorised entitlement risks the signature.
- The code keeps setting `.timeSensitive`, which costs nothing when no Focus is active and is already correct for a Mac App Store build if one is ever made (`docs/mac-app-store-submission.md`). The accepted consequence: under an active Focus, a macOS Important reminder is suppressed like any ordinary notification, and the delivery check still counts it as landed. Someone who relies on breakthrough under Focus should use the Critical tier, which is the app's own overlay and not subject to it.
- iOS is unaffected: the capability is enabled on the `com.pauselet.pauselet` App ID and `.timeSensitive` works there.

### N3. Running the unbundled binary crashes at launch — macOS
- [x] `Sources/ReminderApp/NotificationPresenter.swift:18` `UNUserNotificationCenter.current()` in a stored-property initialiser throws without a bundle. The rest of the shell already guards the unbundled case.
- Fix: treat notifications as unavailable when `Bundle.main.bundleIdentifier` is nil.

### N4. ⌘, opens an empty SwiftUI settings window — macOS
- [x] `Sources/ReminderApp/ReminderApp.swift:14` the `Settings { EmptyView() }` scene installs the command.
- Fix: replace the app-settings command group.

### N5. `pausedAt` is not rounded like the other persisted dates — all platforms (core)
- [x] `Sources/ReminderCore/Store.swift:156` `normalizingDates` rounds `pausedUntil` but not `pausedAt`, so in-memory settings differ from a reload by up to half a second.
- Fix: round it.

### N6. A `"music": null` key makes Windows treat the whole file as corrupt — Windows
- [x] `Windows/Pauselet.Core/Json.cs:466` passes a JSON null to `DecodeMusic`, which throws; the Mac decodes it as none.
- Fix: check `ValueKind` like the other optionals.

### N7. Windows launch can throw when the local time zone has no TZDB mapping — Windows
- [x] `Windows/Pauselet.Core/ReminderEngine.cs:120` and two windows call `DateTimeZoneProviders.Tzdb.GetSystemDefault()` unguarded.
- Fix: one shared resolver with a BCL then UTC fallback.

### N8. Windows importer does not treat a non-breaking space as whitespace — Windows
- [x] `Windows/Pauselet.Core/ExerciseImporter.cs:61` trims only space and tab; the Mac trims all Unicode spaces, so PDF text with NBSP-prefixed bullets splits differently.
- Fix: trim every non-newline whitespace.

### N9. `SpotifyUri.Describe` throws on an empty middle segment — Windows
- [x] `Windows/Pauselet.Core/Music.cs:139` indexes `parts[1][0]` unguarded.
- Fix: guard.

### N10. Non-object elements in the OpenAI envelope throw the wrong exception — Windows
- [x] `Windows/Pauselet.Core/ExerciseInterpreter.cs:350` calls `TryGetProperty` on non-objects; `TestKeyAsync` only catches `AIImportException`, so the failure escapes instead of showing in the settings window.
- Fix: check `ValueKind`; catch-all in `TestKeyAsync`.

### N11. The DPAPI secret store overwrites in place — Windows
- [x] `Windows/Pauselet.Core/SecretStore.cs:84` a crash mid-write leaves an unreadable file that reads back as "no key".
- Fix: temp file and move, as the data store already does.

### N12. Windows test suite is missing several Swift cases — Windows
- [x] `testRestBetweenExercisesIsStoredOnlyWhenSet`, `testStarterSetContainsNoExerciseReminders`, the `VoiceCoachSettingsTests` file, and three `ReminderAITests` cases have no C# port; the golden file carries no exercise or voice keys.
- Fix: port them.

### N13. The settings voice list throws instead of showing "no voices" — Windows
- [x] `Windows/Pauselet.App/SpeechCoach.cs:225` builds the synthesizer outside the `try` and catches only `PlatformNotSupportedException`, so a broken speech stack stops the Settings window opening.
- Fix: construct inside the try; catch everything.

### N14. After a monitor hot-plug the completed coach panel stays collapsed — Windows
- [x] `Windows/Pauselet.App/OverlayPresenter.cs:196` `RelayoutCritical` builds new windows around the shared coach but nothing raises `Changed`, and no window is activated.
- Fix: call `OnCoachChanged()` once on construction; activate the primary after relayout.

### N15. The activity countdown chime plays once per monitor — Windows
- [x] `Windows/Pauselet.App/CriticalOverlayWindow.cs:927` every window runs its own countdown timer and plays Glass at zero.
- Fix: only the primary window chimes.

### N16. Settings list selection is lost on every persist — Windows
- [x] `Windows/Pauselet.App/SettingsWindow.cs:191` `ReloadReminders` replaces `ItemsSource`, clearing the selection, so Edit/Delete do nothing if anything fired since the row was selected.
- Fix: reselect by id after reload.

### N17. Wrong VoiceOver text at the end of a Start All run — iOS
- [x] `iOS/PauseletiOS/Views/TakeoverView.swift:354` the ring's accessibility label hard-codes "Exercise complete" while the headline uses `completionTitle`.
- Fix: use `completionTitle`.

### N18. Coach work repeated on every tick — all platforms
- [x] `activeExerciseID` re-scans the phase list on every access and `rowState` looks the phase up a second time; the finished-exercise sweep allocates two arrays per 0.2 s tick even while paused; Windows `Cancel` raises `Changed` twice and `UpdateCoachRow` rewrites ten dependency properties per row per tick. Small lists today; cheap to tidy while in the file.
- Fix: gate the sweep on a phase change; compare against one resolved phase.

### N19. The closing cue re-spells `completionTitle` — core
- [x] `Sources/ReminderCore/ExerciseSession.swift:217` duplicates the "All exercises complete"/"Exercise complete" choice the property already encodes; C# derives it from `CompletionTitle`.
- Fix: derive it.

---

## iOS

Findings from the iOS whole-app pass, in the same three tiers. Items that are shared with the other platforms (W1 editor clobber, W24 fallback task, N17 VoiceOver text) are listed above.

### Critical

#### IC1. A notification action or alarm Stop that launches the app in the background re-delivers every other pending reminder
- [x] `iOS/PauseletiOS/AppModel.swift:449` `handleNotificationResponse` and `handleAlarmStopped` act on one reminder and then call `rescheduleEverything()` without first folding delivered notifications and alarm fires into the engine or absorbing the backlog — the reconcile step only runs on scene activation, which a background launch never gets. `NotificationPlan.build` then projects every other reminder whose notification already fired as overdue, and `makeRequest` gives an overdue item a 1 s trigger.
- App dead; hourly B fired at 09:00 and sits in Notification Center; at 09:20 the user taps Done on A's notification. B is delivered again at 09:20:01, its anchor moves to 09:20, and both fires are recorded on the next foreground. A critical reminder carried by an alarm is re-armed and re-rung the same way.
- Fix: a `reconcileWithoutTicking()` (delivered fires, alarm registry, backlog) shared by `reconcile()`, and run at the top of both handlers and the significant-time-change path.

### Warning

#### IW1. Answering the lock-screen copy of a takeover can consume tomorrow's slot
- [x] `iOS/PauseletiOS/AppModel.swift:328` `handOffUnacknowledgedTakeover` posts a second actionable copy of the same fire and never removes it. Swiping it away routes `.dismiss` to the engine (`lastAcknowledgedAt` stamped), after which the takeover's own Done is treated as an early completion and stamps the *next* wall-clock slot; tapping Done on the stale copy hours later re-anchors an interval reminder a second time and writes a second `completed` event.
- Fix: remember the hand-off request identifier; remove the delivered copy when the takeover is acknowledged in-app; while the takeover is still pending, a dismiss of that copy is a no-op.

#### IW2. An alarm alerting during activation ticks before reconcile
- [x] `iOS/PauseletiOS/AppModel.swift:490` `handleAlarmAlerting` gates on `isActive`, which is set at `.active` before `activate()` has awaited authorization and run `reconcile()`; its `engine.tick()` then replays a delivered fire — the "tick before reconcile" hazard the class comment warns about.
- Fix: gate on the tick loop having started.

#### IW3. The activity countdown loses time spent suspended
- [x] `iOS/PauseletiOS/Views/TakeoverView.swift:198` decrements an `Int` once per `Task.sleep(1 s)` iteration. Lock the phone for four minutes of a five-minute tilt and the ring still shows ~4:59 on unlock.
- Fix: keep a deadline and derive `remaining` from the wall clock.

#### IW4. Test Voice leaves other apps' audio ducked
- [x] `iOS/PauseletiOS/Views/VoiceCoachSettings.swift:55` `SpeechCoach.speak` activates the shared session as `.playback/.duckOthers`, and only `ExerciseCoach.shutDown()` ever deactivates it. Music stays ducked after the sample sentence until a takeover is dismissed.
- Fix: deactivate when an utterance finishes and no coach owns the session.

### Nice to have

#### IN1. About screens still say there is "no network code in the app at all" — all platforms
- [x] `iOS/PauseletiOS/Views/AboutScreen.swift:95`, `Sources/ReminderApp/AboutTab.swift:94`, `Windows/Pauselet.App/SettingsWindow.cs:1103`. AI import ships on all three; the Settings copy was updated, About was not.
- Fix: mirror the Settings wording — on-device except exercise text the user chooses to send to OpenAI.

#### IN2. A stale announcement fallback can release a re-announced cue early
- [x] `iOS/PauseletiOS/ExerciseCoach.swift:312` (and the Mac twin). Pause 2 s into a cue, resume: the cue is re-spoken and a second fallback armed, but the first fires at 8 s and releases the hold while the cue is still being read. Fixed together with W24 by giving each announcement a generation.
