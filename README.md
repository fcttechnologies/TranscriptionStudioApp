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
scripts/fetch-models.sh               # Sortformer diarizer artifacts (~237MB)
xcodegen generate
open TranscriptionStudio.xcodeproj    # schemes: TranscriptionStudio (Mac) / TranscriptionStudioiOS
```

Tests: `swift test` (package logic) or the Xcode test plans.
Verification audio: `scripts/make-verification-audio.sh` (writes `TestResources/`).
