# Verification — the gates in this repo

The #1 requirement: the app is 100% testable and loggable. The diarizer is FCTSpeech's Core ML
conversion of NVIDIA's Streaming Sortformer, whose fidelity is never assumed — everything below
makes it checkable. (Provenance, the conversion and its own gates: `../FCTSpeech/README.md`.)

## Automated gates (run with the test suite)

1. **Mel-frontend and AOSC gates** live in FCTSpeech beside the code: golden mel spectrograms
   from an independent Python reference, the speaker-cache compression math on synthetic
   tensors, and the streaming state machine against NVIDIA's own reference.
2. **Synthetic ground-truth attribution test** — `scripts/make-verification-audio.sh`
   builds two-voice dialogues (`say`, acoustically distinct voices) with machine-known
   turn boundaries (`TestResources/*.json`). The test diarizes the WAV, optimally maps
   anonymous slots to ground-truth speakers, and asserts frame-level speaker-attribution
   accuracy ≥ 85%. The long variant (>60s) forces cache compression to fire — a short clip
   never exercises it. Runs through the real model under the env flag (see below).
3. **Concurrent-load bench** — `TEST_RUNNER_CONCURRENT_BENCH=1 xcodebuild … test
   -only-testing:TranscriptionStudioTests/ConcurrentLoadBench`
   measures ASR-alone, diarize-alone, and both-at-once on the long clip with thermal states
   (`[BENCH]` lines).

### The real-model gates are env-flagged, not auto-probed

A test that loads a model needs the model installed and pays its Neural Engine specialization
on first load, so those tests are opted in by a human who knows the models are present:

```
TEST_RUNNER_SORTFORMER_MODEL_OK=1 xcodebuild -project TranscriptionStudio.xcodeproj \
  -scheme TranscriptionStudio -destination 'platform=macOS,arch=arm64' test \
  -only-testing:TranscriptionStudioTests/SortformerRealModelTests
```

(Through `xcodebuild` the env var must carry the `TEST_RUNNER_` prefix to reach the app-hosted
test process.)

Without the flag those tests skip and the suite stays green. The mel frontend, the AOSC math
and the streaming state machine are verified in FCTSpeech without the model.

## The agent walkthrough (macOS, drivable)

The Mac app is drivable end to end by an agent through the accessibility tree, so the front
door and every surface behind it are verified by *driving* rather than by reasoning about a
build. Every interactive control carries a stable identifier from `Sources/App/Support/A11yID.swift`
— that file is the driving surface, and a control missing from it is a control an agent cannot
reach.

```bash
xcodebuild -project TranscriptionStudio.xcodeproj -scheme TranscriptionStudio \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/ts-drive -allowProvisioningUpdates build
open -n /tmp/ts-drive/Build/Products/Debug/TranscriptionStudio.app
```

Then read the tree (`UITree` with the app's pid) and click by an element's centre coordinates.
Two mechanics that cost a cycle each if unknown: **the window must be frontmost before the first
click lands** (`osascript -e 'tell application "System Events" to set frontmost of (first process
whose unix id is <pid>) to true'`), and the invisible path-press does not work on this app's
SwiftUI buttons — use a visible click at the element's centre.

**The front-door pass**, which is the one that has to be walked after any change to
`Views/Root/` or the sync bootstrap: the carousel's four pages → `debug.testAccount.signIn`
(reads `FCT_TEST_ACCOUNT_EMAIL`/`FCT_TEST_ACCOUNT_PASSWORD`, signs into the shared test account)
→ `onboarding.continue` to finish the carousel → **`frontDoor.restoring` must appear** → the feed.
The restoring stage is the assertion that matters: it proves no app surface is built while the
account's first pull is in flight. Then `toolbar.settingsToggle` and confirm the sync row reads
"Up to date" against the real server.

`debug.seedLibrary` and `debug.resetLibrary` in Settings put real content in and take it back out
without a relaunch, which is what makes a walkthrough repeatable and what store captures are
driven from.

## Share extension (share-to-transcribe)

The Share extension makes the app a share-sheet target: **macOS** accepts a web **link** →
transcribes it; **iOS** accepts a **media file/video** → transcribes it. The extension never
runs a speech model (it's memory-capped ~120 MB) — it stages the shared item into the App Group
drop-box (`group.com.fcttechnologies.TranscriptionStudio`) and pings the host via the custom
URL scheme `transcriptionstudio://ingest?id=<uuid>`; the host drains the drop-box (on the ping
*and* on every foreground, the iOS safety net) and enqueues a real job.

### Automated coverage (the shared-item classifier tests, always on)

The pure logic is unit-tested with no share sheet or real App Group container (the drop-box
takes an injectable container dir):

- **URL-scheme round-trip** — `IngestURLScheme.ingestURL(id:)` ⇄ `parseIngest`; foreign
  schemes/hosts rejected; an id-less ping still parses (the host drains the whole box).
- **File-vs-URL routing** — `SharedItemClassifier.classify(typeIdentifiers:)`: movie/audio
  UTIs → `.mediaFile`, `public.url` → `.webURL`, media wins when both are advertised, text/
  image/empty → `.unsupported`.
- **Drop-box stage/drain/remove** — a `.url` manifest and a `.file` (bytes copied in) round-
  trip through disk; `remove` clears manifest + staged bytes; `drain` returns oldest-first.
- **Manifest codability** — `PendingIngest` encodes losslessly (default `Date` coding).

Both extension targets compile under warnings-as-errors and embed into their app's PlugIns —
covered by the app builds (`xcodebuild` iOS on a sim, macOS Debug).

---

The checks a person has to perform by hand — the daily loop, the share-sheet taps, the
two-device passes, the Apple-Intelligence and ecosystem device checks — are not facts about this
code and do not live here. They are in the workspace, at
`~/Jarvis/projects/transcription-studio/device-checks.md`.
