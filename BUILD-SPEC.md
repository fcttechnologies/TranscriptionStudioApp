# Transcription Studio — native app rebuild (BUILD SPEC)

*(Working name/repo `TranscriptionStudioApp`. Branding is open — Fernando's call later; don't block on it.)*

You are the orchestrator for this build. Read this whole file, ground on the assets below, write a real build plan, then delegate implementation to Opus/Sonnet coding subagents in clean lanes. Do the thinking and planning; make the subagents do the typing. Verify every build compiles and runs; commit as you go on this repo's `main` (it's a fresh repo, you own it).

---

## Why this exists (the thesis — read this before anything)

This is **NOT a product to sell (yet).** It is two things:
1. **A capability FCT uses every day.** Fernando transcribes constantly (URLs, files, and — new — live meetings/calls). The current tool is a plain, ugly, server-side web app. This replaces it with a genuinely good native daily-driver.
2. **A portfolio / showcase piece.** It has to *demonstrate craft* — elegant, polished, the kind of thing Fernando can pull up next to a client and have it visibly outclass a plain utility. Even though it isn't going public now, it is a showcase of what FCT builds.

Because it's not for sale yet, **everything about shipping-to-sell is OUT of scope** (see Out of Scope). Don't build App Store submission, monetization, or legal/consent flows. Build a *good thing* first; guidelines come after.

## The company (context)

FCT Technologies LLC — a software company. One founder (Fernando) + a persistent AI operating partner. Ships client marketing websites + owned apps. Existing FCT apps are your quality bar and pattern source: **Villain Arc** (shipped iOS app, production SwiftUI/SwiftData/HealthKit craft) and **Personal Context** (in-build iOS app). Match or exceed their polish.

## What to build

A new **native, universal SwiftUI app**, **Mac-first**, iPhone-capable (shared codebase). Two capabilities off one local engine:

### 1. Transcribe (feature-parity with the existing web app, done native)
- Paste a public URL (TikTok / YouTube / any yt-dlp-supported source) → download audio (yt-dlp + ffmpeg) → local transcript. **Mac-only** (yt-dlp/ffmpeg don't run on iOS).
- Drop / pick a media or audio file → local transcript. Both platforms.
- Background job model with visible progress (the existing app polls jobs — replicate that UX natively, better).

### 2. Record (the new capability)
- Live audio recording → **on-device speaker diarization** ("who said what") + transcription. Fully offline.
- Cover both capture paths thoughtfully:
  - **Microphone capture** (AVFoundation) — the simple path (his voice + room / speakerphone).
  - **System / meeting audio capture** (Zoom/Meet/calls) — requires **ScreenCaptureKit + the screen-recording TCC permission** on macOS. This is the true "record a meeting" path. Build it properly with permission handling; ground on current Apple docs.
- Output: a diarized, timestamped transcript (Speaker 1 / Speaker 2 …).

## Non-negotiables

1. **Elegant, showcase-grade UI.** This is a craft demonstration. Warm, considered, polished — the Villain Arc bar. Use the motion-craft and design skills. Not a plain utility.
2. **100% testable and loggable — THE top requirement.** The orchestrator can't verify diarization accuracy by ear (that's a human step). So build the app so *we* can verify it trivially and daily, the way we test the runtime:
   - Structured, readable logs for every pipeline stage (download, extract, ASR, diarization, concurrent run) with timings.
   - An in-app **inspector / debug view** surfacing: raw model outputs, per-segment speaker labels + confidence, ASR confidence, latency per stage, thermal/CPU/ANE load during concurrent ASR+diarization.
   - Deterministic, exercisable flows — Fernando pulls it up, runs a real recording, and can immediately see whether "who said what" is right and where it's wrong.
   - Whatever automated tests are meaningful (engine wiring, job model, parsing) — but the real QA is human-in-the-loop, so *make that loop fast and legible.*
3. **On-device, private, no cloud.** All ASR + diarization local.
4. **Fully working, verified builds.** Every merge compiles and runs on macOS (and builds for iOS). No broken main.

## Tech stack + known unknowns (don't rediscover these)

- **WhisperKit (Argmax)** — Swift-native, CoreML, on-device Whisper ASR (Mac + iPhone). Mature. This is the ASR engine.
- **Streaming-Sortformer-Diar-CoreAI** (HF: `mlboydaisuke/Streaming-Sortformer-Diar-CoreAI`; see also `github.com/john-rocky/coreai-model-zoo`) — on-device diarization, up to 4 speakers, 80ms streaming frame threshold, ~237MB Mac / ~450MB iPhone, fp16, cc-by-4.0. **⚠️ It's a community Core ML conversion — fidelity vs. NVIDIA's original is UNVERIFIED. Assume nothing. Build so we can verify it (see requirement #2), never trust its labels blindly.**
- **yt-dlp + ffmpeg** — URL download/extract. macOS-only. Bundle or shell them cleanly with graceful "not available on iOS" handling.
- **Concurrent ASR + diarization** on one Neural Engine is **unbenchmarked** — two streaming ML pipelines competing for the ANE. Instrument latency/thermal (requirement #2) so we see degradation.

## Grounding — read/ground FIRST, before planning

- **`~/Projects/TranscriptionStudio`** — the existing web app. Port its transcribe pipeline logic: yt-dlp flags, ffmpeg handling, job/progress model, the Whisper settings. Don't reinvent what already works.
- **`~/Projects/VillainArc`** — the SwiftUI/SwiftData craft bar + real patterns. Study it for structure, style, polish.
- **`~/Projects/PersonalContext`** — more current patterns.
- **`~/Projects/JarvisAwake`** (the app under it) — another native app for patterns. **Read-only — a peer flame is actively building in this repo; do NOT edit or commit anything here.**
- **Internal skills** (load them): `apple-skills` (SwiftUI, Xcode/build, `design/motion-craft`), `web-design` (for a later showcase page — not now). Use the **Apple docs skill for latest SDK docs (WhisperKit, ScreenCaptureKit, AVFoundation, SwiftUI) over training knowledge** — the frameworks move fast.

## Out of scope (deferred — do NOT build)

- App Store submission, screenshots, review prep, entitlements-for-sale.
- Monetization / pricing / subscriptions.
- Legal / two-party-consent / recording-disclosure flows.
- Public release / marketing site (the `web-design` showcase page comes later).
- Retiring or editing the existing `~/Projects/TranscriptionStudio` web app — it stays as the headless engine for Jarvis's internal `transcription` skill. Leave it alone.

## Process

1. Ground on all the assets above (apps + docs). Use the Apple docs skill for current SDK APIs.
2. Write a build plan (architecture, module boundaries, subagent lanes). Assume nothing about the community diarizer.
3. Delegate implementation to Opus/Sonnet coding subagents in clean, independent lanes. Give each a tight brief. Verify each lane's build before merging.
4. Commit as you go on `main`. Keep main green.
5. Report back (to the parent flame): what shipped, exactly how Fernando tests it (the verification loop), the diarizer-verification plan, latency/thermal findings, and open risks.

## Constraints

- Work **only in this repo** (`~/Projects/TranscriptionStudioApp`). Do not touch `~/Jarvis`, `~/Projects/JarvisAwake`, or `~/Projects/TranscriptionStudio` (read-only grounding for the last).
- Don't half-ass anything. A strong model thinking carefully and delegating to careful subagents is exactly the standard — this is a showcase of how FCT builds.
- Simulator builds are **arm64-only**: the x86_64 sim slice can't resolve cross-import overlays (`_CoreSpotlight_FoundationModels`), which breaks Release-config sim builds. `project.yml` excludes x86_64 for the app targets; SPM package targets don't inherit that, so a Release-config sim build passes `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` on the command line.
