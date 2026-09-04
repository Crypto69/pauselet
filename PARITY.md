# Bringing iOS and Windows up to parity with macOS

*Written 2026-09-04. A work order for whoever picks up the ports.*

The macOS app gained two significant features this week — a guided **voice
coach** for exercise reminders, and **importing exercises from pasted text**
(parsed locally, or interpreted by OpenAI). Neither has any user-facing
presence on iOS or Windows yet.

This document says exactly where each port stands, what is left, and in what
order to do it. Everything below was checked against the code, not against the
older status docs, some of which are now stale.

**Update, 2026-09-04: iOS is done.** iOS-1 (import UI), iOS-2 (the voice coach)
and iOS-3 (AI import) have all landed; the iOS sections below are kept as a
record of what was built and why. Windows is untouched and remains the whole of
the outstanding work — start at **Win-1**.

## The short version

| | macOS | iOS | Windows |
|---|---|---|---|
| Exercise reminders (model + JSON) | ✅ | ✅ | ✅ |
| Exercise editing — all six fields | ✅ | ✅ *(shares `ExerciseRowEditor`)* | ⚠️ **sets/reps only** |
| Exercise takeover with tick boxes | ✅ | ✅ | ✅ |
| **Text importer (parsing engine)** | ✅ | ✅ *shared core* | ❌ not ported |
| **Import UI** | ✅ | ✅ | ❌ |
| **AI import (OpenAI + key storage)** | ✅ | ✅ | ❌ |
| **Guided voice coach** | ✅ | ✅ | ❌ |
| History — event log | ✅ | ✅ | ✅ |
| History — adherence + range picker | ✅ | ✅ | ❌ **UI never calls it** |
| Music / Spotify | ✅ | ➖ *by design* | ➖ *deferred to v2* |

✅ done ⚠️ partial ❌ missing ➖ deliberately out of scope

**The single most important thing to know:** iOS links `ReminderCore` and runs
its entire test suite on the iOS destination, so `ExerciseImporter` already
built and was tested on iOS before any of this — which is why the iOS work was
UI only, and went quickly. Windows, by contrast, still needs the parser itself
translated.

## iOS

### What is already there

- `ReminderCore` and `ReminderUI` are consumed as a local SwiftPM package
  (`iOS/project.yml:32-36`). The importer, the exercise model and
  `ExerciseSession` (the coach's timeline) are all compiled in.
- The full `Tests/ReminderCoreTests` suite runs on the iOS simulator, so
  `ExerciseImporterTests` is already green on iOS.
- Exercise editing shares `ExerciseRowEditor` from `ReminderUI`, so all six
  fields — including hold and both rests — are already editable
  (`iOS/PauseletiOS/Views/ExerciseListSection.swift:14`). iOS adds swipe to
  delete and drag to reorder.
- The takeover lists exercises with tick boxes
  (`iOS/PauseletiOS/Views/TakeoverView.swift:22-24`). Note the shared
  `ExerciseOverlayRow` already accepts `coachState`, `onStart` and `onCancel`
  (`Sources/ReminderUI/ExerciseOverlayRow.swift:40-42`) — the iOS call site
  simply omits them, so wiring the coach in later needs no change to the row.
- History with adherence, quiet hours, snooze, sounds and the critical tier
  (AlarmKit) are all in place.

### iOS-1 — Import from text *(no AI)* — ✅ **done**

**Why first:** the engine is already there and tested. This is a view and a
button; it is the highest value for the least work on either platform.

- Add an import sheet mirroring
  `Sources/ReminderApp/ExerciseImportSheet.swift`. Same shape: paste box →
  **Read Text** → editable preview rows → **Add N Exercises**. Reuse
  `ExerciseRowEditor` for the preview, as the Mac does, so a mis-parse is
  corrected in place.
- Entry point: beside "Add Exercise" in
  `iOS/PauseletiOS/Views/ExerciseListSection.swift`.
- Carry over the blank-row behaviour: importing clears untouched placeholder
  rows but keeps any the user has typed into
  (`Sources/ReminderApp/ExerciseEditor.swift:69`).
- Consider putting the sheet in `ReminderUI` rather than the iOS target if it
  can be made to fit both platforms — but do not contort it. The Mac sheet is
  470pt fixed and mouse-shaped; a phone needs its own layout. Sharing the row
  editor is probably the right amount of sharing.

**Done when:** a physio's paragraph pasted on an iPhone produces the same rows
it does on the Mac.

**Built as** `iOS/PauseletiOS/Views/ExerciseImportSheet.swift`, entered from
"Import from Text…" beside Add Exercise. It is its own layout — a
`NavigationStack` over a `Form`, with Cancel/Add in the toolbar where a thumb
reaches them — rather than a port of the Mac's 470pt sheet, exactly as this
section suggested. The preview rows are the shared `ExerciseRowEditor`, the
parse is the shared `ExerciseImporter`, and the blank-row rule was carried
over. `ImportSheetContractTests` pins the paragraph → rows contract on the iOS
destination.

### iOS-2 — The guided voice coach — ✅ **done**

`Sources/ReminderCore/ExerciseSession.swift` is pure and already available to
iOS. What is missing is the platform layer:

- A `SpeechCoaching` implementation over `AVSpeechSynthesizer`, mirroring
  `Sources/ReminderApp/SpeechCoach.swift`. The protocol seam is the thing to
  copy — it is what lets the coach be driven without a synthesizer in tests.
- A coach controller mirroring `Sources/ReminderApp/ExerciseCoach.swift`,
  driving `ExerciseSession` from a timer and speaking cues.
- Coach UI on `TakeoverView`: countdown ring, "Set 1 · Rep 3", and
  pause/skip/stop controls. Touch targets replace the Mac's Space/N/X keys.
- Voice settings in `SettingsScreen.swift` — enable, voice picker, pace, Test
  button — writing to the existing `voiceCoachEnabled` /
  `voiceCoachVoiceIdentifier` / `voiceCoachRate` fields, which are already in
  the shared `Settings`.
- **Audio session**: unlike the Mac, iOS needs `AVAudioSession` configured so
  cues play with the screen locked and duck rather than stop other audio.
  Decide deliberately what happens if the user backgrounds the app mid-set.
- Mirror the Mac's sleep behaviour: the coach pauses rather than letting a hold
  silently "complete" (`Sources/ReminderApp/ExerciseCoach.swift:325-339`). On
  iOS the equivalent triggers are backgrounding and screen lock.

**Spec:** `Tests/ReminderCoreTests/ExerciseSessionTests.swift` already pins the
timeline's behaviour on iOS. Only the platform layer needs new tests.

**Built as** `SpeechCoach.swift` (the `SpeechCoaching` seam and `VoiceCatalog`,
near-identical to the Mac's), `ExerciseCoach.swift` (the driver), the coach
panel on `TakeoverView`, and `VoiceCoachSettings.swift`. Both platform
decisions this section asked for were made explicitly:

- **Audio session:** `.playback` with `.duckOthers` and `mode: .spokenAudio`,
  so cues duck music rather than stopping it and are audible on Silent. Set per
  utterance, since `Sounds` moves the shared session to `.ambient` for chimes.
- **Backgrounding:** pauses the session (`ExerciseCoach.sceneDidLeave`), which
  covers both app-switching and screen lock — the iOS equivalent of the Mac's
  pause-on-sleep. Deliberately *not* background audio: coaching a hold nobody
  can see is worse than waiting.

`ExerciseCoachTests` (17 cases) covers the driver: suggestion, row captions,
the announcement gate freezing the clock, one-utterance-after-a-clock-jump, and
that a backgrounded hold does not tick away.

### iOS-3 — AI import — ✅ **done**

iOS does **not** link `ReminderAI` (`iOS/project.yml:32-36` lists only
`ReminderCore` and `ReminderUI`). That was deliberate — it keeps `URLSession`
and `Security.framework` out of the phone build until the feature is wanted.

To add it:

- Add `ReminderAI` to the `PauseletiOS` target's dependencies in
  `project.yml`, then re-run `xcodegen`.
- `KeychainSecretStore` works on iOS **verbatim** — same `Security.framework`
  API, and it already uses
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a key never syncs to
  iCloud. No changes needed.
- `OpenAIExerciseInterpreter` is plain `URLSession` and needs no changes.
- Add an "Exercise Import" section to `SettingsScreen.swift` with a
  `SecureField` and the model picker, mirroring
  `Sources/ReminderApp/AIImportSettings.swift`.
- **Decide first** whether shipping a bring-your-own-API-key field is wanted on
  the App Store at all. It is a reasonable product call to keep iOS
  local-parser-only, and the local parser handles most handouts. If iOS stays
  local-only, say so in `iOS/README.md` so the gap reads as a decision rather
  than an omission.

**Decided: build it.** `ReminderAI` is now a dependency of both `PauseletiOS`
and `PauseletTests`; `KeychainSecretStore` and `OpenAIExerciseInterpreter` were
used verbatim, as predicted. The key field and model picker live in
`Views/AIImportSettings.swift`, and `AIImportController.swift` mirrors the
Mac's. `AIImportControllerTests` (11 cases) covers the key's life in the store
and proves no request is made without one.

One thing this section did not anticipate: the iOS Settings screen claimed
there was "no network code in the app", which stopped being true. That line now
names the one exception instead.

## Windows

Windows is further behind: the core is at parity for *data*, but three whole
features have no C# equivalent, plus two smaller gaps the handoff never
recorded.

### What is already there

- `Pauselet.Core` mirrors Models, Store, Scheduler, ReminderEngine, Projection,
  Music and Exercise, with 197 xUnit tests passing and golden-file tests
  proving a `data.json` round-trips byte-for-byte between Mac and PC.
- The new settings fields (`aiImportEnabled`, `aiImportModel`) and all three
  exercise timing fields are already mirrored in `Models.cs` / `Exercise.cs` /
  `Json.cs`, so **files interchange correctly today** — a programme created on
  a Mac opens on Windows with its timings intact, even though Windows cannot
  yet edit or use them.
- Editor, overlays, tray, history and settings shells exist in `Pauselet.App`.

### Win-1 — Three missing editor fields

`Windows/Pauselet.App/ReminderEditorWindow.cs:403-410` creates only `Sets` and
`Reps` text boxes. Add **Hold**, **Rest between reps** and **Set rest**,
matching the Mac's ranges (`hold 0…300`, rests `0…600`, and both rest fields
disabled when hold is 0). This is small, unblocks nothing else, and stops
Windows silently discarding timings a Mac user set — do it first.

### Win-2 — Port `ExerciseImporter`

Translate `Sources/ReminderCore/ExerciseImporter.swift` to
`Windows/Pauselet.Core/ExerciseImporter.cs`.

The Swift file was **written for this port**: it uses `NSRegularExpression`
with ICU patterns rather than Swift `Regex` builders, precisely so the patterns
re-express in .NET `Regex` with minimal change. Read the file's header comment
before starting.

Translate `Tests/ReminderCoreTests/ExerciseImporterTests.swift` alongside it —
that is the spec, and the house convention is a 1:1 translation with the
`test` prefix dropped and names PascalCased (see how `ExerciseTests.cs` mirrors
`ExerciseTests.swift`). All 25 cases should pass, including the continuous-prose
paragraph and the "then inside an instruction does not split" case.

### Win-3 — Import dialog

Mirror `Sources/ReminderApp/ExerciseImportSheet.swift`: paste box → **Read
Text** → editable preview rows → **Add N Exercises**, entered from a button
beside "Add Exercise" in the editor. Same rule as everywhere: nothing is added
until confirmed, and blank placeholder rows are cleared on import.

### Win-4 — Port `ExerciseSession` and build the coach

- Translate `Sources/ReminderCore/ExerciseSession.swift` —
  `ExercisePhase`, `ExerciseCue`, `ExerciseTimeline`, `ExerciseSession`. It is
  pure value types over an injected clock, so it ports cleanly.
  `Tests/ReminderCoreTests/ExerciseSessionTests.swift` is the spec; translate
  it too.
- Add the coach UI to `CriticalOverlayWindow.cs`: countdown ring, phase
  headline, pause/skip/stop.
- Speech via `System.Speech.Synthesis` or the WinRT `SpeechSynthesizer`, behind
  the same `voiceCoachEnabled` / `voiceCoachVoiceIdentifier` / `voiceCoachRate`
  settings that already exist in `Models.cs`.

### Win-5 — AI import

- **The API key must not go in `data.json`.** That file is plaintext at a path
  shown in the UI, and is copied verbatim to `data.corrupt.json` on a decode
  failure — a key there would leak into backups and support bundles.
  Implement the `SecretStoring` contract (see
  `Sources/ReminderAI/SecretStore.swift`) over
  `Windows.Security.Credentials.PasswordVault`, or DPAPI `ProtectedData` at
  user scope. Roughly 40 lines.
- Port `OpenAIExerciseInterpreter` — `HttpClient` plus
  `System.Text.Json`, hitting `POST https://api.openai.com/v1/responses` with
  Structured Outputs (`text.format.json_schema`, `strict: true`). Keep the
  120-second timeout and the distinction between "offline" and "timed out";
  the Mac conflated them and it sent people to debug a working network.
- Keep the model list and the default in step with the Mac
  (`gpt-5.6-luna` default, then `gpt-5-nano`, `gpt-5-mini`).

### Win-6 — History: adherence and the range picker

Not in `HANDOFF.md`, and easy to miss because the tab exists and looks
finished. `Windows/Pauselet.App/SettingsWindow.cs:529-531` builds a flat
three-column event log — When / Reminder / Outcome — with **no adherence
summary and no 24h/7d/30d picker**.

The logic is already ported and tested: `ReminderEngine.Adherence()` at
`Windows/Pauselet.Core/ReminderEngine.cs:773`, covered by
`ReminderEngineTests.cs:427`. Nothing in `Pauselet.App` ever calls it. So this
is UI-only work against a method that already exists — cheap, and it restores
the answer the app exists to give: are you actually doing them?

### Win-7 — Port `Catalog`

`Sources/ReminderCore/Catalog.swift` has no C# mirror, so the Windows editor
duplicates its data inline — weekdays at
`Windows/Pauselet.App/ReminderEditorWindow.cs:61-65`, icons inside
`SymbolMap.cs`. The interval presets (5, 10, 15, 20, 30, 45, 60, 90, 120, 180,
240 minutes) are **not offered at all** on Windows.

This is exactly the drift `Catalog.swift:3-5` says it exists to prevent. Low
urgency, but worth doing before the two lists diverge further.

### Win-8 — Music *(largest remaining gap, lowest urgency)*

There is no Spotify integration on Windows at all — no equivalent of
`SpotifyController.swift`. `Pauselet.Core/Music.cs` exists, so the model and
per-reminder choice round-trip, but nothing plays. This needs the Spotify Web
API (there is no AppleScript equivalent), which means OAuth and a redirect
flow — substantially more work than the AppleScript path, and worth treating
as its own project rather than folding into this parity pass.

## Suggested order

The three iOS steps (iOS-1, iOS-2, iOS-3) are **done**. What remains is all
Windows, cheap and independent first so each step ships something usable:

1. **Win-1** — three editor fields. Small, and stops Windows silently
   discarding timings a Mac user set.
2. **Win-6** — history adherence. UI-only against a method already ported and
   tested.
3. **Win-2 + Win-3** — port the parser, then its dialog.
4. **Win-4** — the Windows coach. The iOS coach is now a second reference
   implementation alongside the Mac's, and the two agree on everything that
   matters; where they differ is only the platform seam (sleep vs
   backgrounding, `NSSound` vs `AVAudioSession`), which is the part C# has to
   answer for itself anyway.
5. **Win-7** — port `Catalog`, before the duplicated lists drift further.
6. **Win-5** — AI import. The local path is now proven on two platforms.
7. **Win-8** — Windows music, as its own project.

Steps 1–2 are each a day or less. Steps 3–4 are the substantial work.

## Ground rules for this work

- **The Mac encoder defines the file format.** If a change alters the encoded
  bytes, regenerate `Windows/Pauselet.Core.Tests/Fixtures/*.json` **on a Mac**
  by loading and re-saving through `FileDataStore`, and update the twinned
  inline fixture in both `ExerciseTests.swift` and `ExerciseTests.cs`. Never
  hand-edit a fixture to make a test pass.
- **Pure logic goes in the core**, so all three platforms share it and it is
  covered by the one test suite that matters.
- **Never trust a model's output.** Everything the AI path returns goes through
  `Exercise.normalized` before it reaches an editor; there is a test that feeds
  it 99999-second holds and empty names.
- **The import preview is not optional.** Both parser and model get things
  wrong, and these numbers are someone's rehabilitation. Nothing is committed
  until a person has seen it.
- **Update `Windows/HANDOFF.md`** as items land — its "Known placeholders"
  items 7 and 8 correspond to Win-1/Win-4 and Win-2/Win-3/Win-5. It does not
  mention Win-6 or Win-7 at all; add them.

### Stale numbers worth correcting while you are in there

- `Windows/HANDOFF.md` and `Windows/TESTING.md` both say **195** core tests;
  the actual count is **197**. `TESTING.md:254` and the CI workflow header say
  **168**, which is staler still.
- `iOS Implementation Plan.md` at the repo root predates both new features, so
  it has no phase for either, and every box is unchecked despite the work
  having landed. Either update it or retire it — as it stands it misleads.
  **Still outstanding.**
- ~~`iOS/README.md` never mentions the coach, import, or music.~~ **Done:** it
  now has an "Exercise reminders" section covering editing, import, AI import
  and the coach, including the two iOS-specific coach behaviours (audio session
  and pause-on-backgrounding) and why music is deliberately absent.

## Reference files

| Feature | Read this on the Mac side |
|---|---|
| Text parser | `Sources/ReminderCore/ExerciseImporter.swift` + its tests |
| Import sheet | `Sources/ReminderApp/ExerciseImportSheet.swift` |
| Import entry point | `Sources/ReminderApp/ExerciseEditor.swift` |
| Coach timeline | `Sources/ReminderCore/ExerciseSession.swift` + its tests |
| Coach driver | `Sources/ReminderApp/ExerciseCoach.swift` |
| Speech | `Sources/ReminderApp/SpeechCoach.swift` |
| Voice settings | `Sources/ReminderApp/VoiceCoachSettings.swift` |
| OpenAI client | `Sources/ReminderAI/ExerciseInterpreter.swift` |
| Key storage | `Sources/ReminderAI/SecretStore.swift` |
| AI settings | `Sources/ReminderApp/AIImportSettings.swift` |
| Exercise row editor (shared) | `Sources/ReminderUI/ExerciseEditing.swift` |
