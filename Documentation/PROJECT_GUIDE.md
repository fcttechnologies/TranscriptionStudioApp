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

## Structure

Thin app shells (`Sources/MacApp`, `Sources/iOSApp`, xcodegen targets) over one local
package: `TranscriptionKit` (shared: engines, capture, jobs, diagnostics, persistence,
shared UI) + `TranscriptionMacKit` (mac-only: URL ingest, ScreenCaptureKit capture, Mac
shell). Lean extension-safe libraries sit beside them: `ShareKit` (Share-extension
drop-box), `BackgroundAssetsKit` (model pre-download), and `GlanceKit` (Live Activity
attributes + button intents + pure clock/level math, linked by the app and by
`WidgetExtensioniOS` — the widget extension rendering the recording/playback Live
Activities). Regenerate the project with `xcodegen generate` after an edit here — the
`.xcodeproj` is tracked; commit the regenerated result alongside it.

## The seams (contract files — coordinate before changing)

- `TranscriptionKit/Audio/AudioChunk.swift` — `AudioChunk` (16k mono f32 + session-relative
  time + track tag), `CaptureSource`.
- `TranscriptionKit/ASR/AsrEngine.swift` — `AsrEngine`, `AsrSegment` (Whisper confidence
  fields surfaced), `AsrUpdate` (confirmed/unconfirmed).
- `TranscriptionKit/TTS/TtsEngine.swift` — `TtsEngine`, `SynthesizedSpeech` (mono float PCM
  + its own rate, WAV on the way out), `SynthesizedSpeechChunk` + `synthesizeStreaming`
  (ordered incremental audio with latched cancellation; a non-streaming engine gets the
  single-chunk default), `TtsEngineError` (whose `isInvalidRequest` decides a serve 400 from
  a 500). `StreamingWav` is the streamed wire format (unknown-length WAV header + raw s16le).
  Voice and language are plain engine-specific strings, so a second synthesis engine conforms
  here and nothing above it changes; `TTSKitTtsEngine` is the only file that imports TTSKit.
  Consumers: `POST /speak` (chunked streaming), the `speak` CLI subcommand, and the in-app
  read-aloud (`ReadAloudController` + `SpeakTranscriptIntent`).
- `TranscriptionKit/Diarization/DiarizationEngine.swift` — `DiarizationEngine`,
  `SpeakerTurn` (slot + confidence + committed/provisional), `DiarizationResult/Update`.
- `TranscriptionKit/Fusion/TranscriptFuser.swift` — `SpeakerID`, `AttributedSegment`, the
  attribution function (pure, tested).
- `TranscriptionKit/Diagnostics/` — `PipelineStage`/`PipelineEvent`/`PipelineRecorder`
  (every stage logs through this), `InspectorStore` (the in-app inspector's model),
  `SystemLoadSampler`.
- `TranscriptionKit/Mocks/MockEngines.swift` — deterministic fakes for UI work and tests.

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

## Verification

`Documentation/VERIFICATION.md` — the diarizer-verification plan (the community
conversion is presumed guilty until our gates pass) and Fernando's daily testing loop.

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
