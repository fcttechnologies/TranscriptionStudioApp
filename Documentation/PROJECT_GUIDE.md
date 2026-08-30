# Transcription Studio — Project Guide

A native, universal (Mac-first) SwiftUI app: on-device transcription (WhisperKit) of URLs,
files, and live recordings, with on-device speaker diarization (Streaming Sortformer via
Core AI), plus on-device synthesis in the other direction. Two jobs: FCT's daily
transcription driver, and a craft showcase.

**Every model runs on the device; the library lives in the user's account.** Those are two
separate facts and the app never collapses them: no audio is sent anywhere to be transcribed
or synthesized, and the sessions, transcripts, highlights, speaker bindings, tagged places and
the recordings themselves are all stored in the signed-in FCT account so they reach the user's
other devices. Any copy that says otherwise is a defect — see `Documentation/PRIVACY_AND_SAFETY.md`.

## Platform matrix

| | macOS 27 | iOS 27 |
|---|---|---|
| URL transcription (yt-dlp/ffmpeg) | ✅ | — (no subprocess; surface absent) |
| File transcription | ✅ | ✅ |
| Room recording (mic) + diarization | ✅ | ✅ (diarization degrades gracefully if the Core AI model can't load) |
| Meeting recording (system audio + mic) | ✅ ScreenCaptureKit | — |
| Inspector | ✅ | ✅ |

Floor is 27 on both because the diarizer is a Core AI (`.aimodel`) model — the framework
is new in the 27 OSes. Swift 6, strict concurrency.

Because the floor *is* 27, there is no OS-version `#available` gating anywhere. The only
gates are runtime-capability checks — `SystemLanguageModel.default.availability`,
permission grants, `BGTaskScheduler.supportedResources` — and `#if os(…)` where a
capability is genuinely one-platform.

## Structure

The app-build standard's Phase 1 shape: **all code lives in the app target**, under
`Sources/App`, organised by concern (`ASR/`, `Diarization/`, `TTS/`, `Jobs/`, `Sync/`,
`Intents/`, `Views/`, …) with the app shell (`@main`, the `AppShortcutsProvider`, assets,
Info.plist, the entitlements pair) beside them. There is no per-app SwiftPM package; the
only package is **FCTFoundation** (sibling checkout, granular products).

Platform-specific code sits behind `#if os(...)` inside its concern folder: the Mac-only
URL ingest and ScreenCaptureKit meeting capture live in `MacShell/`. Extensions share
app-target files **by target membership** (a path list in `project.yml`): the Share
extension compiles `SharedItems/` (Foundation-only, memory-cap safe forever), the widget
compiles `Glance/`, the Background Assets extension compiles `BackgroundAssets/` layout +
manifest plus `AppGroup.swift`.

`transcribe-cli` is a second Xcode **tool target sharing the same sources** by membership
(everything but the app shell and the CLI's own `@main`). It builds via the
`transcribe-cli` scheme; `scripts/install-serve.sh` installs it to the stable path the
24/7 serve LaunchAgent runs.

Tests are **app-hosted** (`@testable import TranscriptionStudio`) in
`TranscriptionStudioTests`, run on the macOS destination; the CLI has its own logic bundle,
`TranscribeCLITests`. Regenerate the project with `xcodegen generate` after an edit to
`project.yml` — the `.xcodeproj` is tracked; commit the regenerated result alongside it.

## The seams (contract files — coordinate before changing)

- `Sources/App/Audio/AudioChunk.swift` — `AudioChunk` (16k mono f32 + session-relative
  time + track tag), `CaptureSource`.
- `Sources/App/ASR/AsrEngine.swift` — `AsrEngine`, `AsrSegment` (Whisper confidence
  fields surfaced), `AsrUpdate` (confirmed/unconfirmed).
- `Sources/App/TTS/TtsEngine.swift` — `TtsEngine`, `SynthesizedSpeech` (mono float PCM
  + its own rate, WAV on the way out), `SynthesizedSpeechChunk` + `synthesizeStreaming`
  (ordered incremental audio with latched cancellation; a non-streaming engine gets the
  single-chunk default), `TtsEngineError` (whose `isInvalidRequest` decides a serve 400 from
  a 500). `StreamingWav` is the streamed wire format (unknown-length WAV header + raw s16le).
  Voice and language are plain engine-specific strings, so a second synthesis engine conforms
  here and nothing above it changes; `TTSKitTtsEngine` is the only file that imports TTSKit.
  Consumers: `POST /speak` (chunked streaming), the `speak` CLI subcommand, and the in-app
  read-aloud (`ReadAloudController` + `SpeakTranscriptIntent`).
- `Sources/App/Diarization/DiarizationEngine.swift` — `DiarizationEngine`,
  `SpeakerTurn` (slot + confidence + committed/provisional), `DiarizationResult/Update`.
- `Sources/App/Fusion/TranscriptFuser.swift` — `SpeakerID`, `AttributedSegment`, the
  attribution function (pure, tested).
- `Sources/App/Diagnostics/` — `PipelineStage`/`PipelineEvent`/`PipelineRecorder`
  (every stage logs through this), `InspectorStore` (the in-app inspector's model),
  `SystemLoadSampler`.
- `Sources/App/Mocks/MockEngines.swift` — deterministic fakes for UI work and tests.

## Conventions

- `@Observable` only; scope observable reads to the smallest view (a whole-body re-render
  in a Scene/commands builder is the known perf trap).
- No magic numbers in views — `Support/DesignMetrics.swift`.
- OSLog via `Support/Log.swift` categories; never `print`; never log transcript content
  (metrics public, content private).
- Motion per the motion-craft bar: springs (critically damped default), interruptible,
  Reduce Motion honored everywhere (`Support/MotionAccessibility.swift`).
- Swift Testing (`@Test`/`#expect`), in-memory SwiftData per test.
- Models: WhisperKit self-downloads; Sortformer artifacts via `scripts/fetch-models.sh`
  or the in-app downloader (never bundled in git).

### Two measurements that settle arguments before they start

- **Store writes stay on the main context; no path here earns an off-main seam.** A
  transcription job persists **once**, at completion — the whole segment set assigned and saved
  in one transaction, the live transcript held in memory until then — so there is no per-segment
  write and no hot loop of the kind that seam exists to fix. The only path that grows with
  session length is that single bulk save, measured at **128 ms for 2,000 segments** on the M4
  (a three-hour meeting at conversational density, longer than anything real), landing once while
  the UI is already transitioning rather than as scroll jank. `SessionWriteShapeTests` pins the
  shape, and the two writers already off-main — the staging sweep and the sync applier — mint
  their own `ModelContext(container)`. Revisit only if one transaction becomes many, which that
  suite catches.
- **A sync cycle is one push plus a cursor pull of every table, so waking the engine is never
  cheap.** Counted on the wire (`PresenceSyncCostTests`): an idle cycle is **9** round trips and
  makes no push at all, because the push is skipped when the outbox is empty; a cycle with
  anything dirty is **10**. That is why `MacPresence` sits in `LocalSaveTrigger`'s ignore list and
  `PresenceHeartbeat` sends its row through `TranscriptionSync.pushOnly()` — a heartbeat has to
  reach the server but has nothing to learn, and a full cycle cost 600 round trips an hour per
  open Mac against 60. Any future timer-driven row belongs on the same path.

## The front door

`RootView` (`Sources/App/Views/Root/`) is the whole of it, and it is the fleet's sequence with no
per-app variation: the intro carousel, the required three-provider sign-in that ends it, the
account's first pull, then the app. Stages 1 and 2 are **`FCTOnboarding`'s `AccountGate`** — this
app supplies `TranscriptionOnboardingCarousel.items` (four titles, four subtitles, and a picture
of itself per appearance, rendered from live SwiftUI mocks) and wires the gate; it never authors a
pager, a dots row, a device frame or a sign-in surface. **Sign-in is required**: there is no
optional account and no signed-out-but-using-the-app state, and the gate's content closure is not
called until a session exists, so nothing behind it is constructed, queries the store, or starts a
task while the gate is up.

`TranscriptionFrontDoor` (`Sources/App/Services/`) owns what comes after. Its one job is that
**the app is never built while the account's first pull is in flight**: `LibraryRestoreState`
records, per account id, that this device has pulled this account's library down, and until it
has, the window shows the restore stage — or its refusal, with a retry — rather than a feed that
would say "no sessions yet" about a library nobody managed to read. That is what makes the empty
state a fact rather than a guess, and it is why no surface below needs to guard it. Transcription
Studio asks the user nothing of its own, so there is no setup stage; if it ever gains one it
belongs here, after the restore.

## Localization

Ten languages: en, es, zh-Hans, fr, de, pt-BR, ja, ko, it, ru. Two catalogs, both in the app
target — `Sources/App/Localizable.xcstrings` and `Sources/App/AppShortcuts.xcstrings` (the App
Shortcut phrases, which are a separate table and just as undelivered sitting in the wrong one).
The languages are declared in `CFBundleLocalizations` in the Info.plist proper; the
`INFOPLIST_KEY_` build-setting variant is silently ignored and leaves every bundle in the process
English.

**A command-line build never merges newly-extracted keys into a catalog** — that merge is
Xcode-GUI-only — so the gate's drift leg compares both catalogs against the compiler's own
extraction set and fails on a key that is missing or untranslated. When it reports one, harvest it
with `../FCTFoundation/scripts/loc-harvest.py` (byte-compatible with Xcode's writer) and translate
it; never ship the key half-covered.

## Privacy

`Documentation/PRIVACY_AND_SAFETY.md` — the data inventory, what leaves the device and where to,
the permission and logging rules, and the privacy-manifest declarations behind them.
`Documentation/PRIVACY-LOCK.md` covers the per-session lock.

## Verification

`Documentation/VERIFICATION.md` — the automated gates that keep "who said what" honest, and the
accessibility surface that makes the built app drivable. The diarizer's neural core is a model
export whose fidelity is never assumed; `Documentation/SORTFORMER-MODEL.md` carries its
provenance and the recipe to regenerate it. Checks a person has to run by hand are not facts
about this code and live in the workspace, at
`~/Jarvis/projects/transcription-studio/device-checks.md`.

## Building from a fresh clone / worktree

- **Test fixtures:** the real-engine integration tests read `TestResources/*.wav`
  (gitignored). Run `scripts/make-verification-audio.sh` once before the full suite.
- **Mac app signing:** the target's Sign in with Apple + keychain-group entitlements need a
  development team, and
  `project.yml` deliberately leaves it empty — pass it on the CLI:
  `xcodebuild … DEVELOPMENT_TEAM=<team> build`.
- **Simulator limits:** mic capture fails on the simulator (CoreAudio -10868 — the input
  node has no valid format), so live recording can't be exercised there; drive the full
  pipeline via Photos import instead (`ffmpeg`-wrap a TestResources wav into an mp4,
  `simctl addmedia`, then Upload from Photos). Also, `simctl privacy grant` kills the app
  if it's running (TCC) — grant before launch.
