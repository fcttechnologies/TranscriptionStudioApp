# Learnings

Non-obvious traps and decisions a fresh agent on this project should know.

## Share extension (share-to-transcribe)

- **The extension must stay off the heavy deps.** App extensions are memory-capped (~120 MB);
  WhisperKit/SpeakerKit/CoreAI would blow it. The shared drop-box + URL-scheme + classifier
  logic lives in a **Foundation-only** SPM library, `ShareKit`, linked by both the extension
  targets and (via `TranscriptionKit`) the host apps. Never let `ShareKit` gain a heavy dep.
- **Two extension targets, one source.** An Xcode target has a single platform, so there's a
  `ShareExtensionMac` (macOS) and a `ShareExtensioniOS` (iOS); both compile the same
  `Sources/ShareExtension/ShareViewController.swift` (platform-conditional `UIViewController`
  vs `NSViewController`) and differ only in Info.plist (activation rule) + entitlements.
- **Info.plist/entitlements inside the sources path get swept in as bundle resources** →
  `error: Multiple commands produce …Info.plist`. Keep them in `iOS/` + `macOS/` subfolders
  and **exclude those subfolders** from the target's `sources` in `project.yml`; reference the
  plist via `INFOPLIST_FILE` (with `GENERATE_INFOPLIST_FILE: NO`) so xcodegen never regenerates
  the delicate iOS activation predicate.
- **Activation rules:** macOS uses the dictionary form `NSExtensionActivationSupportsWebURLWithMaxCount = 1`
  (one web link). iOS has **no** audio-with-max-count key, so movie/audio/URL is a predicate
  *string* (`SUBQUERY … UTI-CONFORMS-TO "public.movie" || … "public.audio" || … "public.url" …`).
  iOS **does** accept URLs now: a shared link becomes a `.pendingRemote` job (the companion
  feature) — see the companion section below — routed through `AppModel.submitLink`, not
  `startTranscription(.url)` (which is still Mac-only, needs `urlDownloader`).
- **iOS Share extensions can't reliably open their host.** `NSExtensionContext.open` is only
  supported for Today/iMessage points (per Apple docs), and `UIApplication.shared` is
  extension-unavailable. The opener walks the responder chain to a `UIApplication` and calls
  `.open` (not `.shared`, so it compiles). Because that's best-effort, the host **also drains
  the App Group drop-box on every foreground** (`scenePhase == .active`) — that's the real
  safety net. macOS uses `extensionContext?.open` (supported there).
- **Handoff = drop-box + ping, not payload-in-URL.** The extension stages the item (media bytes
  copied into the group container for `.file`; the URL string for `.url`) as a JSON manifest,
  then pings `transcriptionstudio://ingest?id=<uuid>`. The URL is only a trigger — the host
  drains the *whole* box on receipt, so a lost/duplicate ping can't lose or double-ingest work.
- **Copy the staged file OUT before removing the drop-box entry.** `startTranscription(.file)`
  reads the bytes asynchronously in a Task, so the host copies the staged file into its own
  temp dir, starts the job on that copy, then removes the drop-box entry immediately — the job
  owns its bytes and the shared container is left clean (web-app temp parity).
- **`PendingIngest` manifests use default `Date` Codable, not `.iso8601`.** ISO8601 truncates
  to whole seconds, so a drained item wouldn't `==` the staged one (sub-second drift). Default
  `Date` coding (raw `timeIntervalSinceReferenceDate` Double) round-trips losslessly.
- **macOS App Group + non-sandboxed host:** the Mac app is *not* sandboxed (hardened-process
  entitlements, no `app-sandbox`), but a macOS app **extension must be sandboxed** — so
  `ShareExtensionMac.entitlements` has `com.apple.security.app-sandbox = true` **plus** the app
  group; the host just adds the app group. Both resolve the same `~/Library/Group Containers/…`
  path. If the Mac container ever comes back `nil` at runtime, the `<TeamID>.group.…` prefixed
  identifier is the fallback to try (older macOS convention) — but automatic signing with
  `-allowProvisioningUpdates` registers the plain `group.` id, which is what's wired.

## Background Assets (pre-launch WhisperKit model download, iOS)

- **Two API generations — use the modern one.** The WWDC22 API (`checkForUpdates`,
  `manifest`-less callbacks, `NSExtensionPrincipalClass`) is superseded by the SDK-26/27 flow:
  `BADownloaderExtension` conforming to `AppExtension`, driven by
  `downloads(for:manifestURL:extensionInfo:) -> Set<BADownload>` and
  `backgroundDownload(_:finishedWithFileURL:)`. Don't trust training memory here — the framework
  changed shape across releases.
- **It's an ExtensionKit extension, not a classic app-extension.** Product type
  `com.apple.product-type.extensionkit-extension` (xcodegen `type: extensionkit-extension`).
  Info.plist declares `EXAppExtensionAttributes.EXExtensionPointIdentifier =
  com.apple.background-asset-downloader-extension` (note: `asset`, singular) with **NO**
  `NSExtension` dict. Entry point is `@main` — which **requires `import ExtensionFoundation`** or
  you get "cannot use static method 'main()' here" (a warning that's an error under
  `SWIFT_TREAT_WARNINGS_AS_ERRORS`). It embeds into `Extensions/`, not `PlugIns/`.
- **`BADownloadManager.withExclusiveControl` closure is `(Bool, Error?)`, not `(Error?)`.** Apple's
  doc example shows a single `error in` param; the real SDK-27 signature passes
  `(acquiredLock: Bool, error: Error?)`.
- **`BAURLDownload.fileSize` must be the EXACT byte size** or the download fails — take it from the
  real on-disk model (`scripts/gen-ba-manifest.sh` reads `stat -f%z`), never an estimate. The
  turbo variant is 24 files totalling 1638464446 bytes; the AudioEncoder weights alone are ~1.27 GB.
- **The extension can't write to the app's own container** — only the shared App Group. So the
  extension stages finished files in the App Group (`applicationGroupIdentifier:` on the download)
  and the *app* relocates them into WhisperKit's Application-Support download base on launch. Make
  the staging layout mirror the download-base layout (`models/<repo>/<variant>/…`) so it's a
  straight move, and use each download's `identifier` as that relative path so the finish callback
  recovers the destination with no side table.
- **Non-essential downloads** don't gate launch — right for us since WhisperKit downloads on demand
  anyway. Essential downloads block first launch and need `BAEssentialDownloadAllowance`.
- **Foreground fallback is WhisperKit's own download, not `BADownloadManager`.** WhisperKit already
  downloads on demand via a background `URLSession` on iOS; kicking a `BADownloadManager` foreground
  download in the same hot path would fetch the model twice. Keep WhisperKit's as the single runtime
  fallback; `BADownloadManager.startForegroundDownload` is wired + tested as a ready capability for an
  explicit "download now" button, but not auto-invoked.
- **The extension trigger needs the App Store install flow.** The OS wakes the extension before
  first launch only for App Store / TestFlight installs — never a sideload or `xcodebuild install`.
  The code compiles + embeds on any build; only the *firing* needs the Store path. Everything else
  (URL/layout math, manifest parse, staged-file relocation) is unit/integration testable now.
- **`BADownloadDomainAllowList` must cover the HuggingFace LFS CDN, not just `huggingface.co`.**
  `resolve/main/...weight.bin` 302-redirects to a CDN host — allow-list it (verify the exact host
  at ship time; HF's CDN domain can change).

## iOS ↔ Mac companion (link transcription over CloudKit)

Full write-up: `Documentation/COMPANION.md`. The traps worth flagging here:

- **A claimed remote job is processed into the *existing* session, not a new one.** iOS creates the
  `.pendingRemote` session; the Mac must fill *that* row so the result syncs back under the same
  identity. `TranscriptionService.runURLJob(on:isNewSession:false)` is the companion path — it does
  **not** `modelContext.insert` (the row is already in the store) and, on failure, persists
  `.failed` + `errorMessage` (the local `runURLJob(urlString:)` path never persisted a failure,
  because its session isn't in the store until it completes).
- **A Mac's own local URL job and a claimed remote job are both `.inProgress` — the claim marker is
  what separates them.** `claimedAt == nil` ⇒ local (skip); `claimedAt` set ⇒ remote work. This is
  why the claim decision keys on the marker, not just the status. (Also: a local URL job's session
  isn't inserted into the store until it *completes*, so the watcher never even sees it mid-flight.)
- **The `process` closure handed to `RemoteJobWatcher` must be `@MainActor`.** A `@Model` isn't
  `Sendable`; a plain `async` closure is treated as `@concurrent`, so passing the fetched session
  into it is a "sending risks data races" error. Type it `@escaping @MainActor (TranscriptSession)
  async -> Void`.
- **Scans are serialized by an `isScanning` flag.** Launch scan + `NSPersistentStoreRemoteChange` +
  the 45 s poll all call `scan()`; the flag makes overlapping triggers drop, so at most one job
  runs at once. Don't remove it thinking the poll is the only caller.
- **Presence upserts by a plain `deviceIDString` attribute, never a `#Unique`.** CloudKit forbids
  unique constraints; the per-device row is found by a predicate fetch on `deviceIDString` and
  updated in place (insert if absent).
- **FCTFoundation is a dependency, not copied.** `FCTCloudKit` (no deps) + `FCTSync` (→ `FCTCore`)
  are lean, and the package already path-depends on `../FCTFoundation`. `CloudKitSyncMonitor`'s
  `NSPersistentCloudKitContainer.eventChangedNotification` and `CloudKitImportMonitor`'s remote-
  change stream both fire for a SwiftData-backed CloudKit store (SwiftData wraps
  `NSPersistentCloudKitContainer`), so they wire straight in.
- **Shell views read the new environment objects *optionally*.** `@Environment(CloudKitSyncMonitor
  .self) private var x: CloudKitSyncMonitor?` — declaring them optional keeps
  previews/tests that host `StudioHomeView` without the app-root injection from crashing.

## Live Activities + widget extension (Phase 1)

- **`ActivityAttributes` is compile-time unavailable on macOS** even though `canImport(ActivityKit)`
  is true there — guard attribute types with `#if os(iOS) && canImport(ActivityKit)`, not
  `canImport` alone. (Pure helpers like the clock/level math stay unguarded so macOS tests run them.)
- **App Intents in an SPM library DO extract into a widget extension's metadata.** GlanceKit's
  `LiveActivityIntent`s land in `WidgetExtensioniOS.appex/Metadata.appintents/extract.actionsdata`
  (verify with a JSON grep after a build) — no dual-target source compilation needed. The intents
  perform in the *app's* process, so they trampoline through `StudioActivityActions` closures the
  app model registers at init; the extension never links TranscriptionKit.
- **`LM_SKIP_METADATA_EXTRACTION: YES`** on extension targets that carry no App Intents
  (Share ×2, BackgroundAssets) silences the `appintentsmetadataprocessor` "no AppIntents.framework
  dependency" build notice at its cause.
- **The recording activity's clock costs zero updates**: the content state carries a wall-clock
  `timerAnchor` placed so `now − anchor == elapsed`; `Text(_, style: .timer)` ticks natively.
  Same trick for playback: position/rate anchors → `PlaybackClock.wallClockSpan` → self-advancing
  `ProgressView(timerInterval:)`/`Text(timerInterval:)`; updates happen only on transport
  discontinuities (play/pause/seek/rate), which is also what keeps the activity inside its budget.
- **The beta simulator runs the activity but doesn't render it** (Dynamic Island / Lock Screen
  stay blank; `notifyutil -p com.apple.springboard.lockdevice` no longer locks iOS 27 sims).
  Verify lifecycle via `log show --predicate 'subsystem CONTAINS "glanceables"'` + chronod's
  descriptor registration; the visual is a device check (VERIFICATION.md).
- **Multiple worktrees ⇒ multiple `TranscriptionStudio-*` DerivedData dirs.** When installing a
  built app onto a sim, take the DerivedData path from *your own build log* (`grep -m1 -o
  "DerivedData/TranscriptionStudio-[a-z]*" <log>`), never `ls | head -1` — that installed another
  lane's stale app and burned a debugging cycle.
- **`-TSSeedDemoLibrary`** (DEBUG, iOS shell) seeds two playable demo sessions (multi-speaker
  meeting → grouped layout; single-voice memo → flat) with synthesized WAV audio — the sim
  path for exercising the detail view, transport, karaoke and both Live Activities without models.
- **`MPNowPlayingInfoCenter` wiring lives in FCTGlanceables** (`NowPlayingCoordinator` +
  `NowPlayingItem`/`NowPlayingInfoMapper`, tests in FCTGlanceablesTests): publish on
  discontinuities only (the system extrapolates from elapsed + rate; rate 0 = paused), and
  `deactivate()` must both clear the info dictionary and remove every registered command target —
  a leaked target keeps ghost transport controls alive after unload.
