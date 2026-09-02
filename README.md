# Transcription Studio (working name)

Native, universal (Mac-first) on-device transcription + live speaker diarization, and
on-device synthesis in the other direction, by [FCT Technologies](https://fct-technologies.com).
Not for sale (yet): a daily-driver capability and a craft showcase.

This is the native app. The open-source web engine it grew out of, and which still runs headless
behind FCT's own workflows, is [TranscriptionStudio](https://github.com/fcttechnologies/TranscriptionStudio)
(MIT). This repository is **source-available, not open source**: published so the work can be read
and judged, all rights reserved, no licence granted to use, copy, modify or redistribute it.

- `Documentation/PROJECT_GUIDE.md` — structure, contracts, conventions.
- `Documentation/VERIFICATION.md` — the automated gates that verify "who said what".

## Setup

```bash
brew install xcodegen yt-dlp ffmpeg   # yt-dlp/ffmpeg power Mac URL ingest
scripts/fetch-models.sh               # Sortformer artifacts (mel filterbank + metadata)
xcodegen generate
open TranscriptionStudio.xcodeproj    # one scheme, TranscriptionStudio — pick Mac or iOS from the destination menu
```

The Sortformer neural core must be a **locally re-exported** `.aimodel` (the HF-published one
doesn't load on current toolchains) — recipe in `Documentation/SORTFORMER-MODEL.md`. Without
it the app runs with SpeakerKit diarization; WhisperKit self-downloads on first use.

Full gate: `scripts/gate.sh` (the app-hosted suite on the macOS destination, the CLI suite,
both platforms + the CLI built warning-free, artifact reads, Release-Mac hardening check).
Tests alone (app-hosted on the Mac): `xcodebuild -scheme TranscriptionStudio
-destination 'platform=macOS,arch=arm64' test`; real-model gates are env-flagged with a
`TEST_RUNNER_` prefix — see `Documentation/VERIFICATION.md`.
Verification audio: `scripts/make-verification-audio.sh` (writes `TestResources/`).
Onto the phone: `scripts/install-ios.sh [device-udid]` — Release, auto-signed, installed by UDID
over `devicectl`, with every dSYM the build produced retained so a crash from it can be
symbolicated. It runs the old code until it is next launched, which stays a human step.

## Headless CLI

`transcribe-cli` (macOS) drives the same pipeline from the command line — a URL
(yt-dlp-supported) or a local media file → transcript on stdout, progress/errors on
stderr. Transcribe-only (no diarization); the Jarvis `transcribe` tool shells out to it.

```bash
xcodebuild -project TranscriptionStudio.xcodeproj -scheme transcribe-cli \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
# binary at <DerivedData>/Build/Products/Release/transcribe-cli — or use scripts/install-serve.sh,
# which builds release and installs to the stable path:
~/Library/Application\ Support/TranscriptionStudio/bin/transcribe-cli "https://youtube.com/watch?v=…"   # plain text
~/Library/Application\ Support/TranscriptionStudio/bin/transcribe-cli path/to/media.mp4 --json          # segments + timestamps
~/Library/Application\ Support/TranscriptionStudio/bin/transcribe-cli --help                             # all flags
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
transcribe-cli speak "Good morning." --out /tmp/hello.wav --voice serena   # from the installed path
transcribe-cli speak "Good morning." --out /tmp/hello.wav \
    --voice-profile ~/voice-profile.json --voice my-voice
curl -s -X POST localhost:8000/speak -d '{"text":"Good morning."}' -o /tmp/hello.wav
```
