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
  (one web link). iOS has **no** audio-with-max-count key, so movie **or** audio is a predicate
  *string* (`SUBQUERY … UTI-CONFORMS-TO "public.movie" || … "public.audio" …`). iOS deliberately
  does **not** accept URLs — `AppModel.startTranscription(.url)` is Mac-only (needs `urlDownloader`).
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
