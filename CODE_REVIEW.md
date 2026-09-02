# Code Review — windows-port branch (iOS port + core projection layer)

**Date:** 2026-09-02
**Scope:** the uncommitted work on `windows-port` — new `Sources/ReminderCore/Projection.swift`, changes to `Sources/ReminderCore/ReminderEngine.swift`, new core tests (`ProjectionTests.swift`, `ExternalFireTests.swift`), CI workflow changes, and the entire new `iOS/` tree.
**Method:** ten finder agents (line-by-line, removed-behavior, cross-file tracer, Swift pitfalls, wrapper correctness, altitude, reuse, simplification, efficiency, conventions) produced 69 candidates; deduplicated to ~40; five adversarial verifiers confirmed, adjusted, or refuted each claim against the code. Only verified findings appear below. `swift build` / `swift test` pass locally.

**TLDR:** The core engine work and tests are solid, and the iOS shell's UI-to-engine wiring is correct. The serious problems cluster in two places: **(1)** the iOS lifecycle violates the engine's own reconcile-before-tick contract that the Mac app honors, and **(2)** `Projection.projectedFires` is a second hand-maintained implementation of `tick()`'s policy that has *already* diverged from it twice — in one case dropping a reminder entirely.

---

**Resolution (2026-09-02):** every item below is fixed and covered by tests — `swift test` (177 core tests) and the iOS simulator run (209 tests: the core suite on iOS plus the Pauselet plan/alarm tests) both pass. Where the fix differs from the one suggested:

- **C2 / W1 / Architecture:** done as the shared advance step. `Scheduler.nextStep` is the single firing decision; `tick()` applies it once, `projectedFires` loops it, `isDue`, `refreshNextUp`, and `absorbBacklogFromDowntime` are defined through it, and `nextAudibleFireDate` is gone. A three-day side-by-side test (`AdvanceStepTests`) runs the engine against the projection. Timed-pause expiry now re-anchors intervals to the pause's end, matching `resume()` and the projection.
- **C3:** the registry stores the whole `AlarmPlan.Spec` plus when it was scheduled; a relative entry computes the occurrence being acknowledged from its rule (`AlarmPlan.latestOccurrence`), bounded by the schedule time. Storing the spec whole also gives W4 for free (content edits change the spec, so the sync replaces the alarm).
- **C6:** `sync` returns the set of reminders alarms are carrying; `NotificationPlan.build(alarmsCarrying:)` demotes every other critical reminder, so a single failed `schedule` falls back to a notification for that reminder only.
- **W3:** policy decision taken: lock-screen alarms always sound (AlarmKit cannot be silent, and for the critical tier that is the point); the in-app takeover still honours the switch. The help text says so. The sound policy is one core predicate, `Settings.playsSound(for:)`, used on every surface on both platforms.
- **W9:** both paths now record `.fired` at the delivery moment; `recordExternalFire` takes `deliveredAt` (the notification's delivery date, or the alarm's fire date) and keeps the stamp for anchoring. A batch variant persists once.
- **W10:** interval/snooze/catch-up fires use time-interval triggers, wall-clock slots keep floating calendar triggers, and a significant-time-change observer triggers a reschedule.
- **Contract gap (`isEnabled` in `recordExternalFire`):** deliberately *not* added — a notification delivered before the reminder was switched off is a real fire and belongs in history. Instead the guard that matters was added: a stamp at or before the reminder's anchor (`lastFiredAt ?? createdAt`) is a fire the engine could never have produced (a relative rule's occurrence from before the reminder existed) and is ignored.
- **Cross-platform copies:** a `ReminderUI` package target now holds `PriorityDot`, `FlowLayout`, `HelpBadge`/`HelpRow`, and the (fixed) `IntervalPicker`; `EditorCatalog` (symbols, interval presets, weekday table) and `AboutContent` live in core. Both apps import them.
- **Project hygiene:** `iOS/Pauselet.xcodeproj` is gitignored (generated from `project.yml`; CI regenerates it). CI resolves Xcode via `scripts/newest-xcode.sh` and the simulator from `simctl`.

---

## Critical

### C1. Every activation ticks the engine before reconciling delivered fires
- [x] `iOS/PauseletiOS/AppModel.swift:84-91` — `scenePhaseChanged(.active)` runs `startTicking()` (which calls `engine.tick()` synchronously at line 165) *before* the async `Task { await self.activate() }` can run `recordExternalFire` / `absorbBacklogFromDowntime`. Cold launch takes the identical path (`PauseletApp.swift:9-16` does no reconcile at init), so this happens on **every** activation with stale anchors.
- Consequence: every reminder delivered while backgrounded replays as a duplicate banner or takeover on open. Because the tick stamps `lastFiredAt` first, the delivered fires' true stamps are then swallowed by `recordExternalFire`'s `last >= stamp` guard — history records wrong times. `absorbBacklogFromDowntime` also no-ops because the anchor just moved.
- The engine's contract says "call once at launch, before the first tick()" (`Sources/ReminderCore/ReminderEngine.swift:189`); the Mac app honors it (`Sources/ReminderApp/ReminderApp.swift:84-89`).
- **Fix:** await reconcile/absorb before starting the tick loop, on every activation path.

### C2. Projection judges quiet hours at delivery time; tick judges at the slot — a reminder can be silently lost
- [x] `Sources/ReminderCore/Projection.swift:87-89` tests suppression at `fireAt`; `tick()` tests at the slot (`ReminderEngine.swift:354-368`, skip judged with `now: slot` at :367). Both directions verified line-by-line:
  - **Lost reminder:** daily 17:00, paused until 23:00 → projection's `fireAt` (23:00) is suppressed, the wall-clock skip branch (`Projection.swift:90-97`) consumes the slot, next fire tomorrow 17:00. The live engine would deliver at 07:00 stamped 17:00. An iOS user backgrounded through this **never gets that reminder**.
  - **Stale delivery:** daily 23:00, quiet 22:00–07:00, paused until 07:30 → projection delivers at 07:30 stamped 23:00; the live engine records that slot as `.missed` (judged at 23:00).
- Related pre-existing wart: `Scheduler.nextAudibleFireDate` (`Scheduler.swift:269-310`) gives a *third* answer to the same question (countdown shows tomorrow 17:00 while tick fires at 07:00). Fold into the same fix.
- **Fix:** judge suppression at the slot in the projection (or better, the shared advance step under "Architecture" below).

### C3. Single-entry alarm registry vs repeating AlarmKit alarms
- [x] `iOS/PauseletiOS/CriticalAlarmController.swift:23-26` — one `RegistryEntry(fireDate, stampDate)` per reminder, written only by `sync` (:169-172). Daily/weekly critical reminders map to `.relativeWeekly` alarms (`AlarmPlan.swift:69-92`) that repeat system-side without the app running; `handleUpdate` runs only in a live process, so **nothing advances the entry between unattended occurrences**.
- Verified cascade: daily 9:00 critical, app closed Mon+Tue, user taps Stop on Tuesday's ring → `expectedStamp` (:61-64) returns Mon 9:00 → Tuesday's fire recorded as Monday's. Every timing branch from there corrupts history: a duplicate `.fired`, or a spurious `.missed`, or a replayed duplicate takeover if the app opens within the 120 s grace window. Monday's actual ring is never recorded at all.
- **Fix:** per-occurrence registry design — e.g. store the schedule rule and compute the stamp for the occurrence being acknowledged, rather than caching a single (fireDate, stampDate).

### C4. Reschedule passes are unprotected against suspension and against each other
- [x] `iOS/PauseletiOS/NotificationScheduler.swift:98-122` — `refill()` destructively removes all owned pending requests (:102), then serially awaits up to 60 `center.add` calls with errors swallowed (`try?` :121), against a plan snapshotted once and never re-read.
- [x] `iOS/PauseletiOS/AppModel.swift:92-97` — the `.background` call site is a fire-and-forget `Task`; **no background-task assertion exists anywhere in iOS/** (`beginBackgroundTask` / `performExpiringActivity`: zero hits). Suspension mid-pass leaves few or zero pending notifications until the next launch — the app can sleep for days delivering nothing.
- [x] `AppModel.swift:146-148` — `setNeedsReschedule` spawns a bare `Task` per call (17 call sites), no coalescing or generation counter. Overlapping passes interleave across MainActor suspension points; an older pass can re-add stale requests after a newer pass cleared them (stale identifiers embed the stamp, so the newer remove doesn't match them). Reachable from ordinary UI: complete a reminder right after backgrounding.
- **Fix (shared with C5):** one awaited, generation-guarded reschedule wrapped in a background-task assertion; re-check the generation after each await.

### C5. Background-launched actions never guarantee the follow-up scheduling runs
- [x] `iOS/PauseletiOS/AlarmIntents.swift:50-55` — `PauseletAlarmStopIntent.perform` calls `handleAlarmStopped` (`AppModel.swift:365-371`, ends in un-awaited `setNeedsReschedule`) then immediately returns `.result()`. In a background LiveActivityIntent launch the process can suspend before `AlarmManager.schedule` runs → the next occurrence of a **fixed/one-shot critical alarm (i.e. interval reminders — the flagship pressure-relief case)** is never armed.
- [x] `iOS/PauseletiOS/NotificationScheduler.swift:258-283` — `didReceive`'s `defer { completionHandler() }` fires before the un-awaited refill Task runs. A snooze tapped on a locked phone can silently never return (BG refresh floor is 60 min, longer than a typical snooze).
- Engine state itself is safe (persisted synchronously before suspension); only the arming pass is lost, healed at next foreground.
- **Fix:** same as C4 — await the reschedule inside the intent/handler under an assertion before signalling completion.

### C6. `sync()` reports "alarms handle critical" even when scheduling failed
- [x] `iOS/PauseletiOS/CriticalAlarmController.swift:174-180` — the per-spec catch only does `registry.removeValue` and the loop falls through to unconditional `return true`. Verified worse than filed: a **single** thrown `manager.schedule` (alarm cap, transient XPC error) strands that one reminder — `rescheduleEverything` (`AppModel.swift:130-143`) then calls `refill(includeCritical: false)` (`NotificationPlan.swift:57-59` filters critical out), so it has **no alarm and no notification**. Its fires vanish until a later sync succeeds.
- Note: the denied-authorization path is handled correctly (`:141` demotes to notifications); only the thrown-while-authorized path leaks.
- **Fix:** schedule a notification fallback for any spec whose `manager.schedule` throws (or return per-reminder coverage instead of a single bool).

---

## Warning

### W1. Timed-pause behavior contradicts itself, with passing tests on both sides
- [x] Projection re-anchors intervals to the pause's end (`Projection.swift:53-63`; pinned by `ProjectionTests.swift:261-278` `testTimedPauseReanchorsIntervalsToItsEnd` — "Not 10:00 (the natural overdue fire)").
- [x] `ReminderEngine.expireTimedPauseIfNeeded` (`ReminderEngine.swift:398-404`) only clears flags, so a foregrounded app fires overdue reminders the instant the pause lifts (pinned by `ReminderEngineTests.swift:147-164` `testTimedPauseExpiresAndResumesFiring`).
- Manual `resume()` (`ReminderEngine.swift:523-536`) re-anchors — matching the projection — so the auto-expiry path is the outlier. Same state, two behaviors; one fire arrives up to a full interval early/late depending on foreground state (converges after the first fire).
- **Fix:** decide the intended behavior (re-anchor is the likelier intent, matching `resume()`), align the other path, and fix its test.

### W2. `absorbBacklogFromDowntime` is quiet-hours-blind
- [x] `ReminderEngine.swift:203-253` — takes no `Settings`, zero quiet-hours logic; the interval branch (:224-229) tests raw `Scheduler.pendingFireDate` against `now - 120s`, then stamps `lastFiredAt = now` and records `.missed` — for fires the live engine would have delivered at the quiet-window's end (`Scheduler.isDue` suppresses sub-critical during quiet hours and fires at window end). Same class of bug for elapsed snoozes absorbed at :213-216.
- Core bug that exists on macOS too (launch-only there), but iOS calls absorb on every activation and every BG refresh (`AppModel.swift:114-126`, `:403`), making false `.missed` entries routine.
- Verified: delivery itself is usually *not* lost (re-anchored pending still lands at quiet-end); the harm is false history/adherence, plus a delayed fire in some window shapes.
- **Fix:** pass Settings into absorb and skip slots that were merely quiet-hours-deferred, not missed.

### W3. "Play sounds" off is a no-op for critical alarms
- [x] `CriticalAlarmController.swift:298-303` — `soundEnabled == false` yields `.default` (fully audible system alarm sound); the custom sound is honored only when the toggle is ON. Contradicts the help text (`iOS/PauseletiOS/Views/SettingsScreen.swift:81-83` "Plays a sound for Important and Critical reminders") and both other critical surfaces (macOS `OverlayWindow.swift:175-177` and the iOS takeover `AppModel.swift:187-189` are silent when off).
- AlarmKit's `AlertConfiguration.AlertSound` has only `.default` and `.named(_:)` — no silent option (alarms are designed to break through). So the fix is a policy decision, not a missing enum case.
- Hygiene: the branch reads `engine.settings` instead of the `settings` snapshot passed into `sync(:137)` — cannot diverge today but should use the parameter.
- **Fix:** branch on `spec.soundName` (`.named(custom)` vs `.default`) independent of `soundEnabled`, and either amend the help text ("critical alarms always sound") or demote critical to notifications when sound is off.

### W4. Content edits never reach an already-scheduled alarm
- [x] `CriticalAlarmController.swift:161-164` — skip-if-unchanged compares only `RegistryEntry` (fireDate/stampDate) + existence. Title/message/symbol/sound and `soundEnabled` are baked in at schedule time inside `configuration(for:)` (:260, :266, :277-281, :298-303) and nothing else refreshes them. At least the next lock-screen occurrence rings with pre-edit content; heals once dates advance.
- **Fix:** include a content hash in the registry entry (or always re-schedule on engine edits).

### W5. Early completion doesn't reach relativeWeekly alarms
- [x] `iOS/PauseletiOS/AlarmPlan.swift:64-66` — `canRecur` checks snooze/pause/quiet-hours but not a future `lastFiredAt` (which `complete()` sets on early completion, `ReminderEngine.swift:464-468`). The system alarm still rings at the consumed slot; that ring is never recorded (`expectedStamp` returns nil since the registry holds tomorrow's fireDate); history shows two completions and zero fires for the day.
- Note: the feared double-complete consuming tomorrow's slot was **refuted** — `complete()`'s awaitingAck guard (`ReminderEngine.swift:459-463`) blocks it.
- **Fix:** teach `canRecur` (or the sync pass) to drop to a fixed alarm when `lastFiredAt` is in the future, and record the Stop as an acknowledgment of the correct occurrence.

### W6. The `.inactive` window double-delivers
- [x] `AppModel.swift:92-99` — only `.background` calls `stopTicking()`; `.inactive` (app switcher, Notification Center/Control Center over the app, incoming call) sets `isActive = false` while the 5 s main-runloop timer keeps firing. `willPresent` (`NotificationScheduler.swift:243-250`) suppresses the scheduled banner only when `isActive == true`, so during `.inactive` the scheduled banner shows **and** tick's `postImmediate` posts a second one seconds later.
- Narrow but real critical variant: a critical fire in the seconds-long `.inactive` window on the way to `.background` calls `alarms.stopIfAlerting` and strands the occurrence in W8's no-re-alert state. (`handleAlarmAlerting` has a `guard isActive` at `AppModel.swift:384`; the tick-driven `present()` lacks the equivalent.)
- **Fix:** stop ticking on `.inactive` too, or treat `.inactive` as active for `willPresent`.

### W7. The silent switch mutes in-app critical audio
- [x] `iOS/PauseletiOS/Sounds.swift:26` — `.ambient` session (deliberately respects Ring/Silent). The critical branch of `present()` (`AppModel.swift:183-190`) stops the silence-piercing AlarmKit alert (`stopIfAlerting`) then plays through `.ambient` → with the switch on silent, a foreground critical fire is inaudible, while the editor copy promises the tier "pierces Silent mode" (`ReminderEditorView.swift:283`). Takeover is still visually unmissable; background/lock-screen fires keep AlarmKit's piercing audio.
- **Fix:** use `.playback` for critical-tier playback, or leave the AlarmKit alert sounding until acknowledged.

### W8. Unacknowledged critical takeovers have no background re-alert
- [x] `AppModel.swift:183-190` + `scenePhaseChanged(.background)` (:92-97) — backgrounding mid-takeover posts no fallback and re-arms only the *next* occurrence. The takeover survives suspension and re-presents on reopen; the occurrence is fully lost only if iOS terminates the suspended process. Regression vs the Mac's persistent overlay.
- **Fix:** on `.background` with `takeover != nil`, post a time-sensitive notification (or re-arm an alarm) for the unacknowledged occurrence.

### W9. External and live fires date history differently
- [x] `ReminderEngine.swift:310` — `recordExternalFire` records `.fired` at the stamp; `tick()` records at delivery time (:386). Scoped to wall-clock catch-up fires (interval/snoozed/on-time fires have stamp == delivery). Same fire lands in `stats(since:)`/adherence windows differently depending on which path noticed it, and reconciled events append out of chronological order.
- **Fix:** record at delivery time in both paths (keep the stamp for anchoring), or date both at the stamp — pick one.

### W10. Calendar triggers carry no time zone
- [x] `NotificationScheduler.swift:113-116` — `dateComponents([.year,.month,.day,.hour,.minute,.second])` with no `.timeZone` into `UNCalendarNotificationTrigger`. After a device zone change, pending interval/snooze fires (absolute moments) shift by the zone delta or land in the past and never fire, until the next foreground pass. No significant-time-change observer exists. Floating local time is arguably correct for wall-clock reminders; wrong for interval/snooze.
- **Fix:** use `UNTimeIntervalNotificationTrigger` for interval/snooze fires (already used for the ≤1 s case at :111).

### W11. BG refresh handler hygiene
- [x] `AppModel.swift:397-408` — no `task.expirationHandler`; `setTaskCompleted(success: true)` only as the last line of an unstructured Task; and `scheduleBackgroundRefresh()` (:410-414) runs *after* the awaited work, so an overrun both throttles future refreshes and breaks the hourly chain until the next `.background` transition.
- **Fix:** set `expirationHandler` (cancel the Task, `setTaskCompleted(success: false)`), and submit the next request before starting reconcile.

### W12. Widget countdown can crash the widget process
- [x] `iOS/PauseletWidgets/PauseletWidgets.swift:64, 81, 128` — `Text(timerInterval: Date.now...countdown.fireDate)` traps ("Range requires lowerBound <= upperBound") on a render at/just past the fire moment. The `.alert` state flip is async to the widget process, so a stale `.countdown` render is a real race; the Live Activity goes blank at exactly the critical moment (repeated crashes get throttled).
- **Fix:** `Date.now...max(Date.now, countdown.fireDate)` at all three sites.

### W13. Widget version will diverge from the app
- [x] `iOS/PauseletWidgets/Info.plist:19-22` hardcodes `CFBundleShortVersionString 1.0` / `CFBundleVersion 1`; the app uses `$(MARKETING_VERSION)` = 1.0.0 / `$(CURRENT_PROJECT_VERSION)`. App Store Connect flags mismatched extension short-version at upload (ITMS-90473-shaped; hard rejection in some configurations). `CFBundleVersion` coincidentally matches today and drifts on the first bump.
- **Fix:** add both keys to the widget target's `info.properties` in `iOS/project.yml` (:76-81) — the plists are generated, so the fix must land there.

### W14. The "Custom" interval option is unreachable — on both platforms
- [x] `iOS/PauseletiOS/Views/ReminderEditorView.swift:316-336` — the binding setter discards the −1 sentinel (`if $0 != -1`), so selecting Custom from a preset snaps back and the stepper (gated on `!presets.contains(minutes)`) can never appear. The Mac editor has the identical code character-for-character (`Sources/ReminderApp/ReminderEditor.swift:343-357`) — an inherited defect, not a porting one.
- **Fix (both platforms):** track custom mode in separate state, or nudge `minutes` to a non-preset value when Custom is selected.

---

## Nice to have

### Architecture (root cause behind C2 and W1)
- [x] `projectedFires` re-implements `tick()`'s per-fire transition (stamp choice, quiet-hours policy, snooze consumption, pause handling) with only parallel comments keeping them aligned — and it has already diverged twice. Durable fix: one pure single-step **advance** function in core (state + settings + now → stamped state + fire/skip outcome) that `tick()` applies once and the projection loops. Then divergence becomes impossible rather than merely tested-for.
- [x] The audible-sound policy `settings.soundEnabled && priority >= .important` exists at 4+ sites (`NotificationPlan.swift:83`, `NotificationScheduler.swift:194`, macOS `NotificationPresenter.swift:136`, plus the W3 variant and `AppModel.swift:187/:214`). Make it one core predicate, e.g. `Settings.playsSound(for: Priority)`.

### Hot-path efficiency (mechanisms verified)
- [x] Every user action triggers a full uncoalesced cancel-and-rebuild: 17 `setNeedsReschedule` call sites each spawn a fresh Task (`AppModel.swift:146-148`). The C4/C5 fix (coalesced, generation-guarded pass) absorbs this.
- [x] `refill()` awaits ~60 `center.add` calls serially (`NotificationScheduler.swift:121`); most re-added requests are identical to ones just cancelled — diff against the already-fetched pending list, or add concurrently.
- [x] `recordExternalFire` runs a full `persist()` (JSON encode + file write + reassigning three `@Published` properties) + `refreshNextUp()` per fire (`ReminderEngine.swift:311-312`) while both reconcile paths call it in loops (`AppModel.swift:116-118`, `CriticalAlarmController.swift:214-226`). A batch variant would persist once — matters on the first frame after days away.
- [x] `ReminderListView.swift:15` — 1 Hz `TimelineView` wraps the entire List; `sortedReminders()` recomputes `Scheduler.nextFireDate` per reminder and re-sorts every second. Scope the timeline to the countdown text (or `Text(timerInterval:)`).
- [x] `CriticalAlarmController.swift:28-30` — registry `didSet` JSON-encodes to UserDefaults on every mutation, mutated per-alarm inside loops (sync :154/:170/:172/:176, handleUpdate :122, reconcile :225). Mutate a local copy, assign once.
- [x] `HistoryView.swift:17-19` — `recentEvents` computed property filters+sorts up to 2000 events, read twice per body; `adherence` rescans all events per reminder. One local `let` + a single-pass stats dictionary.
- [x] `TakeoverView.swift:111` — `onReceive(Timer.publish(...).autoconnect())` inline in body creates a new publisher per body evaluation and ticks at 1 Hz even for countdown-less takeovers.
- [x] `Projection.swift:140-167` — `NotificationBudget.allocate` re-sorts a layer per depth and the comparator calls `.uuidString` per comparison. Single sort by (depth, fireDate, id) comparing UUIDs directly. Minor.

### Duplication and dead code
- [x] `Sounds.swift:13` vs `:42-44` — the four bundled sound names typed twice (`available` / `availableNames`); derive one from the other.
- [x] "Submarine" critical-default hardcoded three times: `AppModel.swift:188`, `:215`, `CriticalAlarmController.swift:300`. One `Sounds.criticalDefault` constant.
- [x] `Sounds.bundledName` (`:32-38`) — comment promises a tier-default fallback; the function returns nil and each caller invents its own fallback (notifications → system default, alarms/takeover → Submarine). Same imported Mac sound name yields different audio per surface. Reconcile comment and behavior; centralize the fallback.
- [x] `AlarmPlan.spec(for:)` (`:71-105`) builds the same six-field Spec three times differing only in `kind`. Compute `kind` in the switch, construct once.
- [x] `AppModel.present` (:175-192) and `preview` (:206-219) duplicate the priority-routing switch (differences: `isPreview`, post target, and `stopIfAlerting`). Fold into one `route(_:isPreview:)`.
- [x] `CriticalAlarmController` — the registry-lookup + `fireDate <= now` → record guard appears four times (expectedStamp :61-64, handleUpdate :107-109 and :120-123, reconcile :214); `reconcile`'s if/else (:216-226) calls the identical `recordExternalFire` in both branches. Extract one helper; flatten reconcile to record-then-conditionally-remove.
- [x] `ReminderEditorView` init (~:70) restates all five schedule-control defaults in every switch case. Assign defaults unconditionally, override per case.
- [x] Dead: `AlarmPlan.Spec.fixedStamp` (:32-35, zero references, misleading doc comment); iOS `SymbolPicker.columns` (`ReminderEditorView.swift:389-391`, unused — the Mac counterpart is used).
- [x] Misleading comment: `ReminderEngine.swift:306` "exactly as tick() does" — the conditional snooze-consumption guard is deliberately *stricter* than tick's unconditional clear, and correctly so. Fix the comment, not the code.
- [x] Contract gap: `recordExternalFire` never checks `isEnabled` (tick does, via `Scheduler.isDue`). Practically unreachable today; worth a guard for symmetry.
- [x] Cross-platform verbatim copies that would fit a small shared target (or core-data constants): SymbolPicker's 20-symbol catalog, IntervalPicker presets, WeekdayPicker day table (`ReminderEditorView.swift:381/:319/:343` vs `ReminderEditor.swift:401/:341/:367`), About email/links/blurb (`AboutScreen.swift` vs `AboutTab.swift` — 2 of 3 body paragraphs verbatim; the third is a deliberate platform adaptation), PriorityDot tier→color mapping (`SharedUI.swift:9-16` vs `MenuBarView.swift:241-248`), FlowLayout (`SharedUI.swift:28-77` vs `AboutTab.swift:193-242`, verbatim), HelpBadge/HelpRow (`iOS .../HelpBadge.swift` vs `Sources/ReminderApp/HelpBadge.swift`, HelpRow verbatim). The Windows About tab already had to hand-sync once; the priority colors and HelpBadge accessibility behavior are the highest-value shares.

### CI / project hygiene
- [x] `.github/workflows/ci.yml:36` pins `Xcode_26.app` / `Xcode_26*` glob; `:48` pins simulator "iPhone 17 Pro"; `:17` pins `Xcode_16.4.app` for the macOS job. All break on GitHub runner-image rotation; resolve from what the image provides (newest `/Applications/Xcode*.app` via `sort -V`; device from `xcrun simctl list`).
- [x] Before committing the `iOS/` tree (currently fully untracked): decide whether the generated `iOS/Pauselet.xcodeproj` gets gitignored (CI regenerates it with xcodegen anyway; `.gitignore` currently only excludes its xcuserdata, so the pbxproj would come in) or add a `git diff --exit-code` drift check after generation.

---

## Refuted during verification (for the record)

- `NotificationPlan.budget = 60` "magic number" — refuted: named constant with a doc comment explicitly tying it to the 64-cap and the headroom's purpose.
- Removing the `events.contains` scan in `recordExternalFire` — refuted: `update(_:)` can rewind/nil `lastFiredAt` (public var) and several APIs anchor to a non-monotone clock, while delivered notifications are re-read non-destructively on every pass; the scan is genuine defense-in-depth against duplicate reconciliation. (Its comment is still wrong — see nice-to-have.)
- Double-complete consuming tomorrow's slot after a Stop on an early-completed alarm — refuted by `complete()`'s awaitingAck guard (`ReminderEngine.swift:459-463`). The spurious ring + history skew remain (W5).
- Background reschedules corrupting wall-clock grids — refuted: refill never mutates engine state and catch-up stamps keep grids in phase; the real issue is the duplicate burst (folded into C1/C5).
- The iOS rewrite of `Priority.explanation` — deliberate, commented platform adaptation, not drift.
- "Unbounded delivered-notification corruption" — downgraded: `recordExternalFire`'s idempotency makes re-parsing harmless; remaining issue is Notification Center clutter (no `removeDeliveredNotifications` call anywhere — cheap to add in refill for completed/deleted reminders' identifiers).

---

## Suggested order of attack

1. **C1** (awaited reconcile-before-tick) and the shared **C4+C5** fix (one awaited, coalesced, generation-guarded reschedule wrapped in a background assertion) — small, self-contained, removes four failure modes at once.
2. **C2 + W1** via the shared advance-step refactor rather than spot patches (also fixes the `nextAudibleFireDate` third opinion).
3. **C3** — per-occurrence registry design decision.
4. **C6, W3, W12** — each a few lines.
5. Remaining warnings, then the nice-to-have clusters opportunistically.
