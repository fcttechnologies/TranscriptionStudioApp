# iOS ↔ Mac Companion (link transcription over the FCT sync layer)

Lets you paste (or share) a link on iPhone and have your **Mac** transcribe it, with the result
syncing back to the phone — because URL ingest needs `yt-dlp`/`ffmpeg`, which don't run on iOS.
This is **approach A**: the Mac *app* does the work while it's running (no server, no background
extension processing). Both devices share one account's rows through `FCTServerSync`
(`TranscriptionSyncSchema`); the SwiftData store itself is local-only.

## The flow

1. **iOS queues.** Insert Link (the "+" menu) or the iOS Share extension (now URL-activated) calls
   `AppModel.submitLink`. On a device without the URL downloader it creates a
   `TranscriptSession(status: .pendingRemote, kind: .urlTranscription, sourceURLString: …)` and
   saves it. Queuing never depends on the Mac being online — presence is display only.
2. **The sync layer carries** the pending session to the Mac: the phone pushes it, and the Mac
   pulls it on launch, on foregrounding, or on the realtime nudge.
3. **Mac claims + processes.** `RemoteJobWatcher` (Mac-only — started by
   `AppModel.startMacCompanionServices`, guarded on `urlDownloader != nil`) wakes on launch, on
   `NSPersistentStoreRemoteChange`, and on a 45 s poll. It fetches candidate URL sessions, applies
   the pure `RemoteJobClaim` decision, and **claims** one — status → `.inProgress`, stamping
   `claimedAt` + `claimedBy` so no other device double-processes it — then runs the existing URL
   pipeline into that *same* session (`TranscriptionService.runURLJob(on:isNewSession:false)`).
4. **Result syncs back.** On success the session becomes `.complete` with segments + `audioData` +
   `fullText`; on failure it becomes `.failed` with `errorMessage`. Either way it syncs to the
   phone, where the pending card turns into a normal session (or shows the error).
5. **Presence.** `PresenceHeartbeat` (Mac-only) upserts a `MacPresence` row every 60 s. iOS reads
   the most recent `lastSeen` through `MacPresenceStatus` to show "Mac connected" vs "waiting for
   your Mac". Status display only — it never gates queuing.

## The claim lock (why it's safe)

The correctness core is `RemoteJobClaim.decide` (pure, unit-tested):

- `.pendingRemote` URL session → **claim**.
- `.inProgress` URL session with a `claimedAt` newer than `staleAfter` (10 min) → **skip** (a live
  claimant is on it).
- `.inProgress` URL session whose claim has gone stale → **reclaim** (the claiming Mac died
  mid-download; don't wedge the job forever).
- `.inProgress` URL session with **no** `claimedAt` → **skip**. This is how a Mac's *own* local
  Insert Link job (also `.inProgress`, but never claim-marked, and not inserted into the store
  until it completes anyway) is never mistaken for remote work.
- Any non-URL kind, or a `.complete`/`.failed` session → **skip**.

Scans are serialized (`isScanning`), so overlapping triggers (poll + remote-change) never launch
two jobs at once. Sync is last-write-wins by server arrival, so a true two-Mac double-claim within
one push/pull window is theoretically possible; the single-Mac companion case (the target) is fully
covered, and the stale-reclaim path recovers a dropped claim.

## FCTFoundation integration — **dependency, not copy**

`FCTSync`, `FCTServerSync`, `FCTBlobSync` and `FCTAccount` are SwiftPM product dependencies of
`TranscriptionKit`, granular rather than the umbrella. Reused, not reimplemented:

- **`TranscriptionSync`** wraps `SyncEngine` + `BlobStore`; `SyncStatusIndicator` shows a quiet
  syncing/offline/needs-attention glyph in the shell toolbar (invisible when idle), and Settings
  renders the full `SyncStatusRow`.
- **`LibraryBootstrap`** shows "Restoring your library…" over the empty feed on a first launch
  until the first pull resolves (1 s min / 12 s ceiling), and reveals immediately the moment any
  session appears. With no account there is no engine, so it never waits.

## What's unit-tested vs. needs two devices

**Unit-tested** (`Tests/TranscriptionKitTests/CompanionDecisionTests.swift`, container-free +
one in-memory-store test):

- `RemoteJobClaim.decide` — claim / skip-fresh / reclaim-stale / skip-local-unclaimed /
  skip-non-URL / skip-finished / the stale boundary.
- `LinkSubmissionRoute.decide` — has-downloader → local, no-downloader → remote.
- `MacPresenceStatus.evaluate` — absent / connected / stale + the freshness boundary.
- `AppModel.submitLink` on a downloader-less model → persists exactly one `.pendingRemote`
  `.urlTranscription` session with the source URL and no claim marker.

**Needs a real two-device manual check** (real cross-device sync can't be exercised in
`swift test`):

1. Sign both a Mac and an iPhone into the **same FCT account** (Settings → Sign in to sync); launch
   the Mac app (it starts
   the watcher + heartbeat) and the iOS app.
2. On iPhone: Insert Link (or Share a link from Safari) → a card appears reading **"Waiting for
   your Mac…"**; the Insert Link sheet shows the Mac presence badge.
3. Within a sync cycle the Mac claims it (an In-Progress job appears on the Mac); the iPhone card
   flips to **"Transcribing on your Mac…"**.
4. When the Mac finishes, the completed transcript (segments + playable audio) **syncs back** and
   the iPhone card becomes a normal session.
5. Failure path: paste a bad/unsupported link → it ends **`.failed`** on both devices with the
   error message.
