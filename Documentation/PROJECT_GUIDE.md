# Transcription Studio — Project Guide

A native, universal (Mac-first) SwiftUI app: on-device transcription (WhisperKit) of URLs,
files, and live recordings, with on-device speaker diarization (Streaming Sortformer via
Core AI). Fully offline. Two jobs: FCT's daily transcription driver, and a craft showcase.
`../BUILD-SPEC.md` holds the mandate; `../PLAN.md` the grounded architecture decisions.

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
shell). Regenerate the project with `xcodegen generate` — the `.xcodeproj` is gitignored.

## The seams (contract files — coordinate before changing)

- `TranscriptionKit/Audio/AudioChunk.swift` — `AudioChunk` (16k mono f32 + session-relative
  time + track tag), `CaptureSource`.
- `TranscriptionKit/ASR/AsrEngine.swift` — `AsrEngine`, `AsrSegment` (Whisper confidence
  fields surfaced), `AsrUpdate` (confirmed/unconfirmed).
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
