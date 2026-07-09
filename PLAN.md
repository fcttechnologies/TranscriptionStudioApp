# Transcription Studio — Build Plan

The orchestrator's plan of record. BUILD-SPEC.md holds the why; this holds the how. Grounded 2026-07-09 on: the existing web app pipeline, VillainArc/PersonalContext/JarvisAwake patterns, live WhisperKit source (v1.0.0), the Sortformer Core AI conversion (HF card + zoo source + knowledge docs), and current Apple docs (ScreenCaptureKit, Core Audio taps, AVAudioConverter).

## Grounding facts the design hangs on

- **Machine/SDK:** macOS 27 (beta), Xcode 27, Apple M4. `CoreAI.framework` present in the macOS 27 SDK. yt-dlp 2026.07.04 + ffmpeg 8.1.2 via Homebrew.
- **WhisperKit** is now the **`argmaxinc/argmax-oss-swift` monorepo, v1.0.0, MIT**. Products: `WhisperKit` (ASR) and `SpeakerKit` (Argmax's own diarizer — free cross-check baseline). Streaming API: `AudioStreamTranscriber` actor (confirmed/unconfirmed segment model, injectable `audioProcessor: any AudioProcessing`). Confidence per segment: `avgLogprob`, `noSpeechProb`, `compressionRatio`, `tokenLogProbs`; per word: `WordTiming.probability` (with `wordTimestamps: true`). Input contract: 16kHz mono Float32. Mac default model: `openai_whisper-large-v3-v20240930` family; turbo variant is the daily-driver choice. `ModelComputeOptions` can steer each stage off the ANE — the contention knob.
- **Sortformer diarizer** (`mlboydaisuke/Streaming-Sortformer-Diar-CoreAI`, CC-BY-4.0) is **Core AI (`.aimodel`), NOT CoreML** — requires macOS/iOS 27. Stateless fixed-shape graph: `chunk_mel[1,1520,128], spkcache[1,188,512], valid[1,378] → preds[1,378,4], chunk_pe[1,190,512]`. The host owns *everything* stateful: NeMo mel frontend (preemph 0.97, STFT 512/400/160, slaney mel×128, log, **no normalization**), the 188-frame (≈15s) chunk loop, and AOSC speaker-cache compression. Output: per-80ms-frame sigmoid activity per speaker (4 max). Reference Swift port: zoo `SortformerDiarizer.swift` + mel frontend (BSD-3; vendored with notices). Mel filterbank ships as a 128×257 `.f32` blob. Fidelity was byte-gated vs NeMo on **two clips only; DER never re-measured** — we verify ourselves (below).
- **Capture (macOS 15+, so free for us):** one `SCStream` can deliver **system audio (`.audio`) and mic (`.microphone`) as two separately-attributed tracks on one `synchronizationClock`**. `capturesAudio`, `captureMicrophone`, `excludesCurrentProcessAudio`, 16kHz mono requestable (defensively re-convert). Permissions: Screen Recording TCC (preflight `CGPreflightScreenCaptureAccess()`; **app restart after first grant**; deep-link to Settings on deny) + `NSMicrophoneUsageDescription`. `SCRecordingOutput` with `mixesAudioWithMicrophone=false` gives a two-track archival file for free. Echo path: mic-on-speakers bleed → `setVoiceProcessingEnabled(true)` only when output route is built-in speaker.
- **Web-app pipeline to port:** yt-dlp format `bestaudio/best[vcodec^=h264]/best` (TikTok H.265 trap), FFmpegExtractAudio→mp3 192k, `noplaylist`, ffmpeg location detection, per-job-ID temp isolation + startup sweep, job model (steps list / active index / progress / running|done|error), allowed-extension whitelist.
- **Craft patterns (VillainArc bar):** `@Observable` only (scope reads to the smallest view — the command-menu-invalidation trap); JarvisAwake SPM shape (shared Core / MacKit / thin shells); PersonalContext's `AppModelContainer` fallback + test-detection; `Log.swift` OSLog-per-category with structural privacy; `DesignMetrics` no-magic-numbers enum; `MotionAccessibility.swift` lifted near-verbatim; `.sensoryFeedback` not UIKit haptics; Swift Testing; motion per the motion-craft bar (springs, interruptible, reduced-motion always).

## Architecture

xcodegen (`project.yml`, `.xcodeproj` gitignored — regenerate per checkout/worktree) + one local Swift package. Swift 6, strict concurrency, macOS 27 / iOS 27 floor.

```
project.yml                        # TranscriptionStudio (macOS app) + TranscriptionStudioiOS (iOS app)
Package.swift                      # local package, dep: argmax-oss-swift (WhisperKit, SpeakerKit)
Sources/
  TranscriptionKit/                # shared cross-platform core — most of the app
    Support/                       # Log.swift, DesignMetrics, MotionAccessibility, Color+Hex
    Diagnostics/                   # THE #1 REQUIREMENT — PipelineLog events + ring buffer,
                                   # StageTimer, SystemLoadSampler (thermal/CPU/RAM), InspectorStore
    Models/                        # SwiftData: TranscriptSession, TranscriptSegment, SpeakerTurn
    Jobs/                          # ported job model: steps, progress, state, retention
    Audio/                         # AudioChunk (samples+hostTime), converters to 16k mono f32,
                                   # MicCapture (AVAudioEngine, both platforms)
    ASR/                           # AsrEngine protocol + WhisperKitAsrEngine (file + streaming,
                                   # confidence surfaced), model download/lifecycle
    Diarization/                   # DiarizationEngine protocol + SortformerEngine:
                                   #   CoreAIGraphRunner (thin raw-CoreAI wrapper),
                                   #   SortformerMel, AOSC state, preview/commit streaming
                                   # + SpeakerKitEngine (cross-check backend)
    Fusion/                        # speaker frames × ASR segments → attributed transcript
    Ingest/                        # MediaSource abstraction; file ingest (both platforms)
    Views/                         # shared SwiftUI: transcript rendering, live record surface,
                                   # inspector, jobs progress, design components
  TranscriptionMacKit/             # mac-only: URLIngest (yt-dlp/ffmpeg subprocess),
                                   # SystemAudioCapture (ScreenCaptureKit), MeetingCaptureSession,
                                   # mac shell (NavigationSplitView, commands, Settings)
  MacApp/ · iOSApp/                # thin @main shells
Tests/  TranscriptionKitTests/ · TranscriptionMacKitTests/
Documentation/  PROJECT_GUIDE.md · DATA_MODEL.md · VERIFICATION.md
scripts/  fetch-models.sh · make-verification-audio.sh
```

**Contracts-first:** `AsrEngine`, `DiarizationEngine`, `CaptureSource`, `PipelineLogging`, and the `InspectorStore` shapes are defined at scaffold time by the orchestrator, with mock implementations, so all lanes build against stable seams. Lanes do not edit contract files unilaterally — message the orchestrator.

## Pipeline designs

**Transcribe (URL/file):** URL → yt-dlp download (ported flags) → ffmpeg extract → WhisperKit file transcription (VAD chunking) → segments w/ confidence → SwiftData. Job steps mirror the web app (Download → Extract → Transcribe → Done) with per-stage timings logged. File path skips download. iOS: file-only (URL mode hidden, graceful copy).

**Record (the new thing):**
- *Meeting mode (Mac):* one `SCStream` → `.microphone` track = **Me** (attribution free), `.audio` track = remote mixdown → Sortformer for Speaker 1..4. ASR runs per track; fusion assigns "Me" to mic-track segments and diarized labels to system-track segments by time overlap.
- *Room mode (both platforms):* single mic track → ASR + Sortformer both.
- *Live labels vs the 15s chunk:* ASR text streams live (confirmed/unconfirmed). Diarization runs a **stateless preview pass** on the accumulating partial chunk (valid-mask marks real frames, state not committed) every ~2–4s for provisional labels, then a **commit pass** at each full 188-frame chunk advances AOSC state and finalizes labels. Provisional vs final is visually distinct and logged. Preview cost/latency is instrumented — if the M4 can't sustain it alongside ASR, the interval adapts (that's what the thermal/latency inspector is for).
- Archival: `SCRecordingOutput` two-track file (meeting) / AVAudioFile (room), so any session can be re-run offline through either engine — the replay loop for verification.

**Concurrency & ANE contention:** ASR encoder/decoder default `.cpuAndNeuralEngine`; Sortformer runs via Core AI (GPU compute units in the reference port). Both pipelines instrumented (per-inference latency, queue depth, thermal state); `ModelComputeOptions` is the escape valve. Findings go in the report — this is unbenchmarked territory and we're the benchmark.

## Verification & observability (requirement #2 — the point)

**Structured logging:** every stage emits `PipelineEvent{stage, sessionID, timing, payload}` → OSLog (category per stage, privacy-safe) *and* an in-memory ring buffer surfaced live in the app.

**In-app Inspector (a first-class surface, not a debug menu):**
- Pipeline timeline: per-stage latencies, live-updating.
- Raw model outputs: Sortformer per-frame 4-speaker activity heatmap (the actual sigmoids), ASR segment table with `avgLogprob`/`noSpeechProb`/`compressionRatio`/word probabilities.
- Per-segment speaker label + mean activity confidence; provisional vs committed.
- System load: thermal state, CPU, memory, per-inference latency during concurrent ASR+diarization.
- **Click-to-play any segment** — the ear-vs-label loop in one click.
- Diarizer A/B: run SpeakerKit on the same audio, render both timelines against each other.

**Diarizer verification plan (the community conversion is presumed guilty):**
1. *Mel-frontend unit gate:* golden mel for a committed test clip generated by our own Python (librosa/NumPy, no NeMo) via `scripts/`; Swift mel must match on the **linear** stage (the log/silence-floor cosine trap is documented — gate pre-log or on decisions).
2. *AOSC unit tests:* the compression math on synthetic tensors, incl. the padded-count top-k trap the zoo's HANDOFF documents (index shift only visible on long clips).
3. *Synthetic ground truth:* `make-verification-audio.sh` builds multi-speaker WAVs from distinct `say` voices at known turn boundaries → automated Swift Testing integration test computes speaker-attribution accuracy (optimal label mapping, DER-lite) with a pass threshold; also a long (>60s) case so cache compression actually fires (a 2-chunk clip cannot exercise it).
4. *Cross-check:* SpeakerKit vs Sortformer on the same clips, in tests and in the Inspector.
5. *Human loop:* record a real meeting → Inspector shows who-said-what + confidence live → click-to-play to confirm by ear in seconds.
6. *Deferred (forge-able):* NeMo golden-tensor byte gate — the zoo's capture scripts need a PyTorch/NeMo env; not blocking v1.

## Lanes

- **Lane 0 — scaffold (orchestrator, serial):** project.yml + package + targets + contracts + mocks + design tokens + logging spine + SwiftData skeleton + docs; both platforms build green; committed to main before lanes spawn.
- **Lane A — ingest + ASR** (worktree): yt-dlp/ffmpeg port, file ingest, WhisperKit engine (download UX, file + streaming transcription, confidence), job model. First deliverable: WhisperKit resolves + transcribes a real file on this Mac (spike gate).
- **Lane B — capture + diarization** (worktree, the hard one): MicCapture, SCK MeetingCaptureSession + TCC flow, CoreAIGraphRunner, Sortformer port (vendored, adapted, BSD-3 notices), preview/commit streaming, fusion, verification suite (§ above). First deliverable: **spike — the .aimodel loads via raw CoreAI on this Mac and one forward pass returns sane shapes; report back immediately if blocked** (fallback: pin `john-rocky/coreai-kit`).
- **Lane C — app + inspector + polish** (worktree): both shells, Library/Transcribe/Record surfaces on mock engines, the Inspector, design system + motion to the Villain Arc bar (motion-craft review applies).
- **Integration (orchestrator):** merge lanes one at a time (rebase → combined suite → merge), wire real engines, end-to-end verify on real audio, latency/thermal findings, final polish review, report.

Models: Sortformer artifacts pre-fetched to `~/Library/Application Support/TranscriptionStudio/Models/` (runtime downloader + `scripts/fetch-models.sh` reproduce it); WhisperKit self-downloads with progress UI.

## Out of scope (per spec)

App Store/monetization/legal/consent; the web app stays untouched; branding final call is Fernando's (working name: Transcription Studio).
