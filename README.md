# Transcription Studio (working name)

Native, universal (Mac-first) on-device transcription + live speaker diarization, and
on-device synthesis in the other direction, by [FCT Technologies](https://fct-technologies.com).
Not for sale (yet): a daily-driver capability and a craft showcase.

This is the native app. The open-source web engine it grew out of, and which still runs headless
behind FCT's own workflows, is [TranscriptionStudio](https://github.com/fcttechnologies/TranscriptionStudio)
(MIT). This repository is **source-available, not open source**: published so the work can be read
and judged, all rights reserved, no licence granted to use, copy, modify or redistribute it.

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

## Headless CLI

`transcribe-cli` (macOS) drives the same pipeline from the command line — a URL
(yt-dlp-supported) or a local media file → transcript on stdout, progress/errors on
stderr. Transcribe-only (no diarization); the Jarvis `transcribe` tool shells out to it.

```bash
swift build -c release --product transcribe-cli
.build/release/transcribe-cli "https://youtube.com/watch?v=…"        # plain text
.build/release/transcribe-cli path/to/media.mp4 --json               # segments + timestamps
.build/release/transcribe-cli --help                                  # all flags
```

The WhisperKit model self-provisions on first use (download progress → stderr).

It also speaks — on-device synthesis behind one `TtsEngine` seam with two engines routed by
voice id. `speak <text> --out <path>` writes a 16-bit mono WAV; `--voice`/`--language` pick a
TTSKit preset speaker and its language (listed in `--help`), and `--voice-profile <json>`
adds that profile's zero-shot cloned voices (CoreML LuxTTS, English, 48 kHz) to the same
roster — a `--voice` naming one of them routes to the cloner, anything else to the presets.
The same capability rides the serve API as `POST /speak {text, voice?, language?}`, streamed
chunked as `audio/wav`. Both synthesis models self-provision on first use, load lazily per
engine, and idle out of memory on their own clocks, independently of the recognition model.

```bash
.build/release/transcribe-cli speak "Good morning." --out /tmp/hello.wav --voice serena
.build/release/transcribe-cli speak "Good morning." --out /tmp/hello.wav \
    --voice-profile ~/voice-profile.json --voice my-voice
curl -s -X POST localhost:8000/speak -d '{"text":"Good morning."}' -o /tmp/hello.wav
```
