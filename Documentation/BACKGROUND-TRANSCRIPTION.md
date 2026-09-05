# Background transcription (BGContinuedProcessingTask)

Closes the gap where a **file/link transcription job** — recognition + diarization, all
GPU + Neural-Engine work — had no background cover: only live-mic recording did (the `audio`
`UIBackgroundMode`). Background the app mid-transcription and, before this, the job was open to
suspension. Now, on iOS, the run is wrapped in a **`BGContinuedProcessingTask`** (iOS 26+) so the
system keeps it running after the app leaves the foreground.

macOS has no such suspension limit, so there it's a plain passthrough (`#if os(iOS)`).

## What runs where

- **`BackgroundExecution.run(job:title:_:)`** (`Sources/App/Views/App/BackgroundExecution.swift`)
  — the cross-platform entry `AppModel.startTranscription` calls for both the file and URL paths.
  macOS: a bare `Task` wired to `job.task`. iOS: routes through `ContinuedTranscriptionTask`.
- **`ContinuedTranscriptionTask`** (iOS-only, same file) — one shared coordinator that owns the
  single wildcard task registration and, per job:
  1. Submits a `BGContinuedProcessingTaskRequest` with a per-job identifier
     (`<bundle-id>.transcription.<job-uuid>`), `strategy = .queue`, and `requiredResources = .gpu`
     when `BGTaskScheduler.supportedResources.contains(.gpu)`.
  2. On the system's launch handler, runs the transcription work and **mirrors the job's existing
     progress model** (`TranscriptionJob.progress` / `.stageText`) into `task.progress` +
     `task.updateTitle(_:subtitle:)` ~once a second — accurate progress is what lets the system
     tell a running job from a stuck one.
  3. Routes a system-side **Cancel** (task expiration) to `TranscriptionJob.cancel()`.
- **`JobProgressBridge`** (same file) — the pure fraction→`completedUnitCount` + terminal-state
  math, unit-tested in `Tests/TranscriptionStudioTests/BackgroundExecutionTests.swift` (no task/sim
  needed).

If the OS declines the request (e.g. `tooManyPendingTaskRequests`), it falls back to a bounded
`beginBackgroundTask` assertion so short/medium jobs still finish.

## Configuration (must stay in sync)

- **`project.yml`** → iOS `BGTaskSchedulerPermittedIdentifiers`:
  `com.fcttechnologies.TranscriptionStudio.transcription.*` (wildcard; the concrete per-job id
  is composed at runtime from `Bundle.main.bundleIdentifier` in `ContinuedTranscriptionTask`).
  Regenerate the Info.plist with `xcodegen generate` after editing.
- **`Sources/App/TranscriptionStudio.entitlements`** (the iOS set) →
  `com.apple.developer.background-tasks.continued-processing.gpu = true` (the Background GPU Access
  capability). Required for background GPU use; a real-device/distribution build needs the
  provisioning profile to carry it. Simulator builds don't validate it.

## The Live Activity — system-provided, NOT a custom widget

`BGContinuedProcessingTask` renders **its own system Live Activity** automatically (confirmed in
Apple's docs + WWDC25-227): the app supplies `title` / `subtitle` / `progress` and the *system* UI
displays them on the Lock Screen / Dynamic Island with a Cancel control. There is **no developer
ActivityKit widget** for it.

So this delivers the brief's functional requirement — "a transcribing Live Activity with stage
text + progress + a cancel that calls `TranscriptionJob.cancel()`" — through the **system**
activity (subtitle = live stage text, progress bar = job fraction, Cancel → `job.cancel()`), not a
new widget in `WidgetExtensioniOS`. A custom ActivityKit "Transcribing" activity was deliberately
**not** built: it would show a *second, redundant* Live Activity for the same job alongside the
mandatory system one. If a branded custom activity is wanted *instead of* the system one, that's a
follow-up product decision — it can't suppress the system activity, so the two would coexist.

Foreground progress is already covered by the in-app job cards (`JobStore`); this change is purely
about background survival + the background progress UI.

## On-device verification (NOT verifiable in a build lane — do this on a real device)

The actual background-survival behavior needs a physical iOS 26+/27 device (background GPU access
and continued-task scheduling don't behave on the simulator, and require the provisioned GPU
entitlement). Steps:

1. Build + run on a real device (signed with a team whose profile includes the Background GPU
   Access entitlement).
2. Start a **long** file transcription — a 20–30 min audio/video file so the job runs long enough
   to background it mid-run (a short clip finishes before you can test).
3. While it's in the **Transcribing** stage, **background the app** (Home / swipe up — do NOT swipe
   it out of the app switcher; the system cancels tasks when the app is force-quit).
4. Confirm:
   - A **system Live Activity** appears (Lock Screen + Dynamic Island) titled with the job title,
     its subtitle tracking the stage text ("Transcribing…", "Attributing speakers…", "Saving…")
     and its progress bar advancing.
   - The job **completes** while backgrounded — reopen the app and the finished session is saved
     (check `PipelineRecorder`/inspector timings show it ran through, not stalled).
   - Tapping **Cancel** in the Live Activity stops the job (session not saved; job shows cancelled).
5. Optional: on a device that reports `BGTaskScheduler.supportedResources.contains(.gpu)`, confirm
   via Instruments that GPU work continues after backgrounding (vs. suspending without the task).

Until run on-device, treat background survival as **implemented to the documented pattern but not
runtime-verified**.
