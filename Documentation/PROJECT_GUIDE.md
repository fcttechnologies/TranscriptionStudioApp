# Transcription Studio — Project Guide

A native, universal (Mac-first) SwiftUI app: on-device transcription (WhisperKit) of URLs,
files, and live recordings, with on-device speaker diarization (Streaming Sortformer via
Core AI), plus on-device synthesis in the other direction. Fully offline. Two jobs: FCT's
daily transcription driver, and a craft showcase.

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

## Privacy

`Documentation/PRIVACY_AND_SAFETY.md` — the data inventory, what leaves the device and where to,
the permission and logging rules, and the privacy-manifest declarations behind them.
`Documentation/PRIVACY-LOCK.md` covers the per-session lock.

## Verification

`Documentation/VERIFICATION.md` — the automated gates that keep "who said what" honest, the
device passes host tests can't reach, and Fernando's daily testing loop. The diarizer's neural
core is a model export whose fidelity is never assumed; `Documentation/SORTFORMER-STATUS.md`
carries its provenance and the recipe to regenerate it.

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
