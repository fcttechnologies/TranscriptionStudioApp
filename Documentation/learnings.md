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
- **Phase 3 write boundary lives in `FCTIntelligence.ConfirmableWrite`** (draft→`PendingWrite.confirm()`).
  A `.write` action is NEVER a model-callable `Tool` — the `AIToolSafety.vetted*` seams still reject
  `.write` from any `LanguageModelSession`. The app-side commit does EventKit; the field mapping
  (`EventDraftMapper`, `EventKitBuilder`) is where the unit tests live (constructing `EKEvent`/
  `EKReminder` needs no permission, so field mapping is testable; `save`/access is a device check).
- **Calendar uses write-only scope; Reminders has NO write-only scope** (`requestFullAccessToReminders`
  is the minimal available — grounded via sosumi TN3152). Info.plist keys differ accordingly
  (`NSCalendarsWriteOnlyAccessUsageDescription` vs `NSRemindersFullAccessUsageDescription`).
- **`CNContactPickerViewController` needs no Contacts permission** (out-of-process) — so speaker→contact
  binding is permission-free; only mention resolution (a `CNContactStore` read) needs `NSContactsUsageDescription`.
  The naming sheet resolves mentions ONLY when access is already granted (`MentionResolver.canResolve`),
  so opening it never surprises the user with a prompt.
- **Siri name resolution = Spotlight `keywords`.** Bound speaker names + extracted mentions are folded
  into `TranscriptSessionEntity.people` (`@Property(indexingKey: \.keywords)`) via `SessionPeople`, and
  `SpeakerAssignmentStore` reindexes the session on every bind — so a name query matches even when the
  transcript only said "Speaker N". Reindex is async; allow a beat after binding before testing search.
- **Contacts resolver = `FCTContacts` (new module).** `ContactMatcher` is pure/framework-free (testable);
  it returns an unambiguous best match only when one exists (two same-first-name contacts → nil, caller
  disambiguates). The CNContactStore provider creates the store per-call (it's not `Sendable`).

## Background transcription (BGContinuedProcessingTask — iOS 26+)

See `Documentation/BACKGROUND-TRANSCRIPTION.md` for the full design. Traps:

- **The system provides the Live Activity — you don't build one.** `BGContinuedProcessingTask`
  renders its own system Live Activity from `title`/`subtitle`/`progress`; there is NO developer
  ActivityKit widget for it (confirmed sosumi + WWDC25-227). A custom "Transcribing" activity in
  `WidgetExtensioniOS` would be a *second, redundant* Live Activity for the same job — deliberately
  not built. The brief's "stage text + progress + cancel" is delivered via the system activity
  (subtitle = `job.stageText`, progress = `job.progress`, Cancel → `TranscriptionJob.cancel()`).
- **`BGTaskScheduler.submit(_:)` is DEPRECATED in iOS 27** → use `submitTaskRequest(_:)`
  (async throws) / `submitTaskRequest(_:completionHandler:)`. The iOS-26 docs still show `submit`;
  the SDK-27 deprecation warning fails the warnings-as-errors bar. `submitTaskRequest` must NOT be
  called from the main thread (it may block; completion lands on an arbitrary queue) — submit from
  a detached `Task`, building the (non-Sendable) request off-main from Sendable strings.
- **Continued-task handlers register LAZILY, not at didFinishLaunching.** Unlike other `BGTask`s,
  register the wildcard handler when the intent is first expressed (first job submit) — guarded so
  it happens exactly once (a second `register` of the same identifier is fatal).
- **Wildcard identifiers:** Info.plist `BGTaskSchedulerPermittedIdentifiers` holds `<bundle-id>.<ctx>.*`;
  register the wildcard once and submit concrete per-job ids (`…<ctx>.<uuid>`) under it.
- **`.gpu` is the only `Resources` option** — gate it on `BGTaskScheduler.supportedResources.contains(.gpu)`
  and pair with the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement.
  ANE (Neural Engine) work continues regardless; the resource specifically covers GPU. A real-device
  build needs the provisioning profile to carry the entitlement (simulator doesn't validate it).
- **Launch handler ↔ MainActor bridge:** register with `using: .main` and adopt isolation via
  `MainActor.assumeIsolated` in the handler — the `BGContinuedProcessingTask` is non-Sendable, so
  this avoids crossing an actor boundary to touch the `@MainActor` job model. `expirationHandler`
  fires on an arbitrary queue → capture only the Sendable identifier and hop via `Task { @MainActor in }`.
## Suggestion chips (the proactive delivery surface)

- **The chip surface is a pure mapping, not a store.** `ActionSuggestions.suggestions(for:includeContacts:now:)`
  derives chips from the extracted `@Model`s on every body pass; `SuggestedActionsRow` is a thin
  renderer. All chip policy (kind order, dated-before-undated, past-event staleness vs. past-due
  action items kept, `done` filtering, dismissal) lives there and is unit-tested — don't add
  policy in the view.
- **Dismissal is a per-item string set on the session** (`dismissedSuggestionIDs: [String]`,
  ids shaped `"event:<uuid>"`), CloudKit-additive like `attendees`. A *confirmed* write also
  dismisses its chip via the `onConfirmed: (() -> Void)? = nil` hook on the two confirm views
  (nil from the shell's App Intent route — behavior there is unchanged).
- **Chips clamp, they don't stretch: under a horizontal `ScrollView`'s ideal-size proposal,
  `.frame(maxWidth:)` sizes to the child's own width clamped to the max** — so short item text
  hugs and only long text truncates. (Under a *finite* proposal the same frame would expand to
  the max and pad short chips with dead space.) The day hint (`· Thu, Jul 16`) sits outside the
  truncating frame so a long title can't swallow the useful part.
- **Beta-sim crash reports naming `intelligencetasksd` / `BackgroundShortcutRunner` are system-
  daemon noise, not the app.** The sim tooling's crash detector surfaces any fresh `.ips`; before
  reacting, confirm the app's pid is still alive (`simctl spawn <udid> launchctl list | grep
  <bundle-id>`). Chasing these as app crashes burns cycles on nothing.
- **`SimTap` by label on an element scrolled out of view can land on the wrong target** (it taps
  the stale coordinate — in our case an off-screen chip's tap hit the *previous* chip's dismiss ×).
  Scroll the element into view first, or tap by fresh on-screen coordinates from the settled map.
## Cross-device data freshness + native sectioning (roadmap §6, §12)

- **`@Query(sectionBy:)` needs a STORED key path — a computed one traps at runtime.** SDK-27
  sectioned queries section at the store level; passing `sectionBy: \.someComputedVar` compiles
  fine but fatally asserts on first render deep in `SwiftData`/`_SwiftData_SwiftUI`
  (`EXC_BREAKPOINT`, `_assertionFailure`). The home feed's day sections use a stored
  `TranscriptSession.daySectionKey` (`yyyy-MM-dd`, current calendar/TZ) derived from `createdAt`
  at `init`. The human header ("Today"/date) is derived off each section's own sessions, so the
  key only has to *group* (lexicographic `yyyy-MM-dd` order == chronological, so newest-first
  `createdAt` sort ⇒ newest-day-first sections).
- **`@Model` silently drops property observers — `didSet`/`willSet` never fire on assignment.**
  Keeping `daySectionKey` in sync via a `didSet` on `createdAt` compiled but never ran (a unit
  test that back-dated `createdAt` caught it — all keys stayed at "today"). The macro rewrites
  stored props into `_$backingData` accessors and doesn't wire observers in. Derive-once in `init`
  instead (via a defaulted `createdAt:` init param); `createdAt` is a creation stamp the app never
  reassigns, so it stays correct. Don't reintroduce a `didSet` expecting it to fire.
- **A bare `@Query` still misses remote CloudKit imports in SDK 27** — the reason the feed adds
  freshness on top of `@Query`. `@Query` re-evaluates for local writes but not for an
  `NSPersistentCloudKitContainer` remote import merged on the background context (Apple's own
  remedy for observing remote changes is `HistoryObserver`, not `@Query`). The feed re-identifies
  its `SessionFeed` (`@Query(sectionBy:)`) on `SessionStoreObserver.remoteGeneration` (the
  `HistoryObserver.eventCounter`, which fires only on `remoteChange`) — a rare cross-device import
  forces a fresh fetch, while frequent local writes update the list in place (scroll preserved).
- **Incremental Spotlight reindex = a SEPARATE `HistoryObserver` from the feed's.**
  `SpotlightIndexObserver` (wired in both app roots after `reindexAll`) keeps this device's named
  Spotlight index fresh with sessions changed on the *other* device while the app runs — the gap
  launch-only `reindexAll` leaves open. On each `eventCounter` bump it `fetchHistory`-s since its
  last token, drops our own local writes (author filter), and incrementally
  `index`/`deindex`-es the affected sessions. Insert/update → fetch by `persistentModelID` and
  `index`; delete → recover the UUID from the history **tombstone** (why `TranscriptSession.id`
  is `@Attribute(.preserveValueOnDeletion)` — the `PersistentIdentifier` is useless once the row
  is gone). Pure filters (author + entity) live in `SpotlightReindexDecision` (unit-tested).
- **Author filter = "skip our own writes, process everything else" (fail-open).** Local writes
  carry `AppModelContainer.localAuthorName` (`ModelContext.author`, stamped on `mainContext` at
  launch via `stampMainContextAuthor()` + on background contexts via `localContext()`); the
  observer skips them (already indexed inline) and processes any other author — notably CloudKit's
  import author. Unknown/absent author is processed, never skipped, so a real cross-device change
  is never missed. `mainContext.author` can't be set in the `shared` factory (it's `@MainActor`,
  the factory is nonisolated) — hence the launch-time stamp.
- **Two-device Spotlight-freshness check (on-device, can't be automated — one sim can't do CloudKit
  sync).** Sign both a Mac and an iPhone into the same iCloud account with the app installed and
  synced. (1) On the Mac, create/rename a session; on the iPhone (app already foregrounded, NOT
  relaunched) pull down Spotlight after sync lands (a few seconds) and search its title — it should
  appear without relaunching. (2) Delete a session on the Mac; confirm it drops out of the
  iPhone's Spotlight results, again without relaunch. (3) Repeat Mac↔iPhone reversed. Before this
  observer, only a relaunch (which runs `reindexAll`) refreshed the index. Runtime sanity for the
  sectioning + no-crash path is covered on the sim (`-TSSeedDemoLibrary`); the cross-device index
  freshness itself needs the two-device setup.
- **iOS Release build on the simulator fails in FCTFoundation with `cannot find type
  'SpotlightSearchTool'` unless you force arm64.** That type comes from the
  `_CoreSpotlight_FoundationModels` cross-import overlay, which only resolves in the arm64 slice.
  Release defaults `ONLY_ACTIVE_ARCH=NO`, so xcodebuild also builds the x86_64 sim slice where the
  overlay is absent and the build fails — even with a concrete arm64 `-destination`. Pass
  `ONLY_ACTIVE_ARCH=YES ARCHS=arm64` for any Release-config simulator build (Debug is fine — it
  defaults to active-arch only). Device archives are unaffected (device is arm64).


## Moat features — confidence mode + per-session privacy lock

- **ASR confidence was already captured + surfaced, always-on, per-segment.** `Confidence.asrScore`
  collapses `exp(avgLogprob)·(1−noSpeechProb)` to a `[0,1]` legibility score; `ConfidenceText`
  (FCTComponentsUI) draws a dotted underline whose weight rises as the score falls, rendered by
  `TranscriptTurnView`. The moat adds a **per-word** layer on top: when word timestamps were
  captured (`AsrWord.probability`, stored in `StoredSegment.wordsJSON`), a detail-view toggle
  flags the individual low-confidence *words*, not just the segment. Word data is absent unless
  `AppSettings.wordTimestamps` is on (off by default), so the per-word view **degrades to the
  per-segment score** cleanly. The flagging/normalization is pure + unit-tested
  (`ConfidenceFlagging`).
- **SwiftData+CloudKit sync exclusion is per-configuration/per-model-TYPE, never per-instance.**
  Grounded via sosumi: `cloudKitDatabase` is a `ModelConfiguration` property; a `@Model` type
  belongs to exactly one configuration. There is no API to keep *some* `TranscriptSession` rows
  local while others sync. True per-session sync exclusion would need private sessions in a
  **separate local-only `ModelContainer`** (`cloudKitDatabase: .none`), routed at *creation*
  (a post-hoc toggle can't honestly promise "never left the device" — it already synced). That
  fractures the single-container assumption wired across the feed fetch, `SessionStoreObserver`,
  `AppModel.openSession`, `TranscriptSessionEntity`/Siri, Spotlight, and playback — and SwiftData
  object graphs can't move between containers. So per the moat brief's explicit fallback, the
  **biometric lock is built fully** and CloudKit exclusion is **honestly documented** as a known
  limitation (see `Documentation/PRIVACY-LOCK.md`), not faked.
- **Private ⇒ withheld from the assistant surface.** A biometric-locked session that Siri could
  still read aloud or Spotlight could surface would be an obvious hole, so `isPrivate` also skips
  Spotlight indexing, the relevant-entity donation, and FM highlights extraction. This is the
  clean, correct slice of "keep it local" achievable without the container split.
- **`NSFaceIDUsageDescription`** is required on both app targets (project.yml `info.properties`)
  or the Face ID prompt crashes. `LocalAuthentication` is a system framework — importing it in
  TranscriptionKit auto-links; no `project.yml` dependency needed.

## MetricKit production diagnostics + StateReporting (roadmap §10)

- **MetricKit was fully redesigned in SDK-27 — do NOT use training memory of `MXMetricManager`.**
  The surface is now the Swift-first `MetricManager`: an *instantiable* class (not a shared
  singleton), created once and held for the app's lifetime. Reports arrive as non-throwing
  `AsyncSequence`s — `manager.metricReports` (daily `MetricReport`) and `manager.diagnosticReports`
  (per-event `DiagnosticReport`) — iterated with `for await` in two long-lived detached tasks (one
  per sequence; iterating the *same* sequence twice, or creating multiple managers with the same
  domains, splits reports non-deterministically). `MetricReport`/`DiagnosticReport`/`MetricResult`/
  `DiagnosticResult` replace `MXMetricPayload`/`MXDiagnosticPayload` and their typed properties.
- **macOS 27 IS supported now** (historically MetricKit was iOS-only). Both MetricKit and
  StateReporting list macOS 27.0+; the SPM package builds clean on macOS with a plain
  `import MetricKit` / `import StateReporting` (system frameworks auto-link, no Package.swift or
  project.yml change). So both app shells wire it — no `#if os` / `#available` guard needed.
- **State reporting lives in a SEPARATE `StateReporting` framework, coordinated only by a domain
  string.** `MetricManager(enabledStateReportingDomains: [StateReportingDomain(rawValue: domain)])`
  enables aggregation; `StateReporter.reporter(for: domain)` (a *per-domain process singleton*)
  emits transitions via `reportTransition(to: label)`. The two never reference each other — they
  meet at the reverse-DNS domain constant (`PipelineStateLabel.stateDomain`). So the `MetricManager`
  can live in the app shell while the `StateReporter` wrapper lives in `AppModel.live()` (passed to
  `PipelineRecorder`); nothing needs threading between them.
- **`reporter(for:)`'s metadata type params default to `Never.self`** — you can report bare state
  labels (`reportTransition(to: "diarization")`) with no metadata types at all. Only reach for
  `@ReportableMetadata` structs if you actually want stable/volatile context.
- **StateReporting rate-limits and DROPS data if called in a tight loop.** The pipeline records
  many events/sec while streaming, all mapping to the same coarse state → dedup so a transition
  fires only when the *label changes* (a stage boundary, human-timescale). `PipelineStateReporter`
  tracks the current label under a `Mutex` and skips unchanged/ambient (`.system` → nil) stages so
  an interleaved system log line can't clobber the state a concurrent hang should be attributed to.
- **The report payloads are `Codable` but NOT constructible in a test** (no public inits; they only
  arrive from the system). So the decision/formatting layer (`MetricsSummary.swift`) is written
  over own value types and unit-tested; `MetricsReporter` holds a thin adapter that reads the real
  reports into them. Same pattern the brief prescribed for the old MX types — still needed.
- **`MetricReport.intervalEntries.fullDayEntry` is NON-optional** (`Array.fullDayEntry` returns
  `MetricReport.IntervalEntry`, not `IntervalEntry?`) — don't `if let` it.
- **`HitchTimeMetric` / `ScrollHitchTimeMetric` expose `.ratio` (`Measurement<Unit>`, dimensionless),
  NOT a histogram.** Only `HangTimeMetric` and `TimeToFirstDrawMetric` are `Histogram<UnitDuration>`.
  Histogram bucket bounds are `Measurement<DimensionType>` (use `.converted(to: .seconds).value`),
  not raw `Double`. `MetricResult` histograms give buckets only, so a mean is an approximation
  (bucket-midpoint-weighted) — `HistogramSummary` computes and labels it as `~avg×count`.
- **What can only be verified with real field payloads:** the adapters (`MetricsReporter.summary(for:)`
  for both report kinds) run only when the system delivers a report — metrics daily, diagnostics
  when an event fires *and* the device is in a sampling group with detection enabled. There is no
  way to synthesize a `MetricReport`/`DiagnosticReport` to exercise the adapter end-to-end; it's
  proven by construction (grounded field types) + the pure-layer tests, and confirmed live only by
  reading OSLog `category:metrics` from a real install over days (TestFlight/App Store, not a sim).
## Recording-location metadata (roadmap §11, opt-in)

- **`CLGeocoder` + `reverseGeocodeLocation` are DEPRECATED in the 26/27 SDKs** ("use MapKit" /
  "use `MKReverseGeocodingRequest`") — a deprecation *warning* that fails the app targets'
  `SWIFT_TREAT_WARNINGS_AS_ERRORS`. The roadmap docs (§11/§6) still name `CLGeocoder`; that's
  stale. Reverse-geocode with `MKReverseGeocodingRequest(location:)` (failable init) →
  `try await request.mapItems` → the first `MKMapItem`. SPM `swift build` compiles the
  deprecation as a plain warning (no warnings-as-errors there), so a green `swift build` does
  NOT prove the xcode app build is warning-clean — check the deprecation output explicitly.
- **`MKMapItem.init(placemark:)` and the `.placemark` property are DEPRECATED in SDK 27.** Build
  a map item with `init(location: CLLocation, address: MKAddress)` and
  `MKAddress(fullAddress:shortAddress:)`; set `.name` for the label. `openInMaps(launchOptions:)`
  returns `Bool` and is NOT `@discardableResult` — `_ = mapItem.openInMaps()` or the unused
  result trips warnings-as-errors.
- **A coarse, privacy-forward place name off an `MKMapItem`:** `mapItem.name` is a real
  landmark/business label *only* when `mapItem.pointOfInterestCategory != nil` — for a plain
  address it's the street, which is more precise than a location tag should be. Prefer, in order:
  the POI name (only when categorized) → `mapItem.addressRepresentations?.cityName` (coarse city)
  → `mapItem.address?.shortAddress` (last resort). Keep that priority a pure function over plain
  strings (`PlaceNameFormatter`) so it's unit-tested without MapKit hardware; the live fix +
  geocode + Maps-open are on-device checks.
- **One-shot location = `CLLocationUpdate.liveUpdates()`** (the modern async-sequence replacement
  for the delegate-driven `CLLocationManager.requestLocation`): iterate, take the first
  `update.location`, break; bail on `authorizationDenied`/`authorizationDeniedGlobally`/
  `authorizationRestricted`; race the stream against a `Task.sleep` timeout so it never hangs.
  `CLLocationUpdate` is `Sendable`, so the iteration can run in a nonisolated task and hand back
  only extracted `Double`s (never the non-`Sendable` `CLLocation`). A separate `CLLocationManager`
  is kept only to `requestWhenInUseAuthorization()` on first capture.
- **AppIntents `IndexedEntity` `@Property(indexingKey:)` is 1:1 with a `CSSearchableItemAttributeSet`
  key** — two `@Property`s can't both map to `\.keywords` (the second assignment wins). To fold a
  second keyword source (a place name) in beside people names, aggregate them into ONE property's
  value (`SessionKeywords.values(for:)`), don't add a second keyword-mapped property. Renaming the
  Swift property (`people` → `keywords`) doesn't touch the on-disk Spotlight attribute (`\.keywords`
  is unchanged), so no index migration.
- **Location capture is fire-and-read, not awaited at stop.** `RecordingController` starts the
  capture at `start()` and reads `capturedLocation` at `stop()` without awaiting — a recording long
  enough to matter has resolved the fix+geocode by the time it ends; a sub-timeout recording
  persists without a location (silent degrade), never blocking the stop/finishing path.
## Foundation Models — PCC escalation for long transcripts (roadmap §8, Item A)

- **`PrivateCloudComputeLanguageModel.contextSize` is `async throws`; `SystemLanguageModel.contextSize`
  is a plain sync getter.** Grounded via sosumi (both pages). The PCC one is
  `nonisolated(nonsending) final var contextSize: Int { get async throws }` — so `try await
  pcc.contextSize`, and read it *inside* the do/catch that already guards the PCC generation so a
  failed context-size fetch degrades to on-device like any other PCC failure. The on-device value
  is read synchronously via `AIModelProfile.onDeviceContextSize` (FCTIntelligence), which wraps
  `SystemLanguageModel.default.contextSize` (`@backDeployed`, non-throwing, nonisolated).
- **The on-device context window is 4,096 tokens on the base model** (confirmed in Apple's
  "Managing the context window" article). The old hard 12_000-char ceiling ≈ 3k tokens of that.
  The runtime budget now derives from the live `contextSize`: `max(0, contextTokens −
  reservedContextTokens) × charactersPerToken` with `charactersPerToken = 4`,
  `reservedContextTokens = 1_024` → reproduces ~12,288 chars at 4,096 tokens and grows on a larger
  window. The reserve covers instructions + question + prompt scaffolding + the response.
- **Reuse FCTIntelligence's tier machinery — do NOT reimplement the PCC availability probe.**
  `ModelAvailability.isPCCAvailable` checks the `com.apple.developer.private-cloud-compute`
  entitlement *before* constructing the model, because **constructing
  `PrivateCloudComputeLanguageModel()` without the entitlement is an uncatchable `fatalError`**
  (documented in FCTIntelligence, sim-proven twice). `SessionIntelligence` injects
  `any ModelAvailabilityProbing` (default `ModelAvailability()`) and only constructs the PCC model
  once `plannedTier` returns `.privateCloudCompute` (which requires `isPCCAvailable`). Never new up
  the PCC model speculatively.
- **The escalation policy is a pure static (`generationTier` + `transcriptCharacterBudget`), wired
  to live inputs by the injectable instance seam `plannedTier(forTranscriptCharacters:)`.** Escalate
  to PCC *only* on strict on-device overflow AND PCC available; boundary (== budget) stays
  on-device; overflow with PCC unavailable degrades to trimmed on-device (never a new error). This
  keeps every branch unit-testable with a `FixedAvailability` fake + a fixed `contextSizeProvider`,
  no Apple Intelligence hardware — matching the existing injectable-status posture.
- **A default argument in a `public init` may only reference public/`@usableFromInline` symbols.**
  The `contextSizeProvider` default must reference `AIModelProfile.onDeviceContextSize` (public)
  directly, not an internal `static` helper (compiles as an error, not a warning).
- **`TitleGenerator` stays on-device (4k-char budget), and `HighlightsExtractor` routes through
  FCTIntelligence's `GuidedExtractor`/`StructuredGenerator`** — those already own the on-device→PCC
  tiering for *structured* generation. The `SessionIntelligence` escalation is the *free-text*
  (summarize/answer) counterpart; there is no shared free-text escalation seam yet (atlas candidate).

## Foundation Models — Dynamic Profiles verb unification (roadmap §8, Item B)

- **`LanguageModelSession.DynamicProfile` shipped as named** (grounded via sosumi — surprising, the
  roadmap wrote it speculatively). It's a real protocol with `Profile`, `DynamicInstructions`, a
  `DynamicProfileBuilder` result builder, and `LanguageModelSession(profile:history:)`
  (`convenience init(profile: sending some DynamicProfile, ...)`). A `DynamicProfile.body` resolves
  to exactly one active `Profile` — the builder enforces "one profile active at a time" at compile
  time via `if / else if / else` (and `if let`), unifying heterogeneous branch types the way
  ViewBuilder does. Config modifiers: `.model(_:)`, `.temperature(_:)`, `.samplingMode(_:)`,
  `.reasoningLevel(_:)`, `.maximumResponseTokens(_:)`; also `.historyTransform`, lifecycle hooks.
- **`.model(_:)` takes `any LanguageModel`** — so one call site accepts either
  `SystemLanguageModel.default` or a `PrivateCloudComputeLanguageModel` without a branch-type split.
  Both `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` conform to `LanguageModel`. This
  is how Item A's model choice threads into the unified profile: the caller passes the concrete,
  already-availability-checked model in; the profile just applies `.model(model)`.
- **The unification is a single-source-of-config win, not a runtime-switching one — be honest about
  it.** DynamicProfile's headline feature is switching config mid-session as app state changes; TS's
  three verbs are independent one-shot sessions, so that capability isn't exercised. What the
  refactor genuinely buys: the summarize/ask/title instructions + per-verb temperature live in ONE
  `TranscriptVerb`/`TranscriptModelProfile` pair instead of three drifting
  `LanguageModelSession(instructions:)` sites. The per-call `respond(to:)` no longer passes
  instructions or `GenerationOptions(temperature:)` — both move into the profile.
- **Keep the verb→instructions/temperature mapping in a Foundation-Models-free enum** so it stays
  pure/unit-testable on any platform; only the `DynamicProfile`-conforming struct sits behind
  `#if canImport(FoundationModels)`. The profile's *resolved* config can't be asserted without a live
  session, so the enum mapping carries the unit tests and the conformance is proved by the build.
- **Moving temperature from a call-site `GenerationOptions` to a profile `.temperature` modifier is
  behavior-preserving:** call-site `respond(options:)` overrides the profile (documented precedence:
  call-site > innermost profile > dynamic-profile default), so dropping the call-site options lets
  the profile's value apply unchanged.
