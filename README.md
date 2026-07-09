# Transcription Studio (working name)

Native, universal (Mac-first) on-device transcription + live speaker diarization.
FCT Technologies. Not for sale (yet) — a daily-driver capability and a craft showcase.

- `BUILD-SPEC.md` — the mandate.
- `PLAN.md` — grounded architecture + lane plan.
- `Documentation/PROJECT_GUIDE.md` — structure, contracts, conventions.
- `Documentation/VERIFICATION.md` — how "who said what" is verified.

## Setup

```bash
brew install xcodegen yt-dlp ffmpeg   # yt-dlp/ffmpeg power Mac URL ingest
scripts/fetch-models.sh               # Sortformer artifacts (mel filterbank + metadata)
xcodegen generate
open TranscriptionStudio.xcodeproj    # schemes: TranscriptionStudio (Mac) / TranscriptionStudioiOS
```

The Sortformer neural core must be a **locally re-exported** `.aimodel` (the HF-published one
doesn't load on current toolchains) — recipe in `Documentation/SORTFORMER-STATUS.md`. Without
it the app runs with SpeakerKit diarization; WhisperKit self-downloads on first use.

Tests: `swift test`; real-model gates `SORTFORMER_MODEL_OK=1 swift test --filter Sortformer`;
concurrency bench `CONCURRENT_BENCH=1 swift test --filter ConcurrentLoadBench`.
Verification audio: `scripts/make-verification-audio.sh` (writes `TestResources/`).
