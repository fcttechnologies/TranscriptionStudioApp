# Background Assets — pre-launch WhisperKit model download (iOS)

The iOS app ships a **Background Assets** downloader extension so iOS fetches the WhisperKit
speech model *before the app's first launch*. A person installs the app from the App Store and
the ~1.53 GB `large-v3-turbo` model is already downloading (or done) by the time they open it —
no first-run "Downloading speech model…" wait.

This is the **self-hosted, unmanaged** Background Assets flow (our files, on HuggingFace; our
manifest schema), not Apple-Hosted asset packs.

## How it works

1. The app declares `BAManifestURL` (+ the other keys below) in its Info.plist.
2. On install/update — before the app can launch — the system downloads the manifest from
   `BAManifestURL` and wakes **`BackgroundAssetsExtension`** (`WhisperModelDownloaderExtension`),
   handing it the manifest's on-disk location.
3. The extension parses the manifest and returns a `Set<BADownload>` — one **non-essential**
   `BAURLDownload` per model file, each pointing at its HuggingFace `resolve/main` URL, with its
   exact byte size and the shared App Group as the destination.
4. The system downloads the files. As each finishes, `backgroundDownload(_:finishedWithFileURL:)`
   moves it into the App Group at
   `…/BackgroundAssets/WhisperKit/models/argmaxinc/whisperkit-coreml/<variant>/<relpath>`.
5. On the app's first launch, `BackgroundAssetsModelInstaller.installStagedModel()` relocates the
   staged tree into WhisperKit's download base
   (`~/Library/Application Support/TranscriptionStudio/Models/whisperkit/models/…`). WhisperKit
   then finds the model already present and skips its own download.

The extension can't write to the app's own container (it isn't shared), so it parks files in the
App Group and the app moves them the last hop on launch. The staging layout mirrors the
download-base layout, so the relocation is a straight per-file move.

**Non-essential** (not essential): the app is fully usable while the model downloads — WhisperKit
downloads on demand if a job runs before Background Assets finishes — so the download never gates
the app's launch.

## The pieces

| Piece | Path |
|---|---|
| Lean shared kit (manifest schema, HF-URL + layout math) | `Sources/BackgroundAssetsKit/` |
| Downloader extension (`@main BADownloaderExtension`) | `Sources/BackgroundAssetsExtension/` |
| App-side installer + foreground fallback | `Sources/TranscriptionKit/ASR/BackgroundAssetsModelInstaller.swift` |
| Launch hook | `Sources/App/TranscriptionStudioApp.swift` (`.task`, iOS branch) |
| Committed manifest (a copy of the hosted file) | `Sources/BackgroundAssetsKit/Resources/whisperkit-model-manifest.json` |
| Manifest generator | `scripts/gen-ba-manifest.sh` |

`BackgroundAssetsKit` stays Foundation-only (no WhisperKit), like `ShareKit`, so the extension
fits its tight memory sandbox.

## Config (project.yml → generated Info.plist / entitlements)

Host app Info.plist (the iOS slice — `com.fcttechnologies.TranscriptionStudio`):
- `BAManifestURL` — where the system fetches the manifest.
- `BAAppGroupID` — `group.com.fcttechnologies.TranscriptionStudio` (shared with the extension).
- `BAMaxInstallSize` — `1638464446` (uncompressed total; shown on the App Store).
- `BAInitialDownloadRestrictions` — App-Review-enforced ceilings on the post-install download:
  `BADownloadAllowance` (non-essential total + margin), `BAEssentialDownloadAllowance` (`0`), and
  `BADownloadDomainAllowList` (the HuggingFace hosts).

The shared App Group is on both the host and the extension. The
`com.apple.developer.background-assets` entitlement is on **neither**: it isn't provisionable on a
sideloaded / automatic-signing dev build (Xcode: *"not found and could not be included in
profile"*), and Background Assets never fires on a sideload anyway, so carrying it today is pure
build friction. It goes back on both entitlements files at ship — see the ship-time steps below.
Like the App Group and Sign-in-with-Apple entitlements it registers through automatic signing
(`-allowProvisioningUpdates`) once a real `DEVELOPMENT_TEAM` signs the build; a teamless simulator
build strips all provisioning-dependent entitlements (only `hardened-process` survives codesign),
which is expected and identical to how the App Group behaves there.

The extension is an **ExtensionKit** extension (`com.apple.product-type.extensionkit-extension`):
its Info.plist declares the point via `EXAppExtensionAttributes.EXExtensionPointIdentifier =
com.apple.background-asset-downloader-extension` with **no** `NSExtension` dict, and the entry
point is `@main` (needs `import ExtensionFoundation`). It embeds into the app's `Extensions/`
folder (not `PlugIns/`).

## Foreground fallback

If the app opens with the model absent (see "what needs the App Store" below), the guaranteed
fallback is **WhisperKit's own download**, which `prewarmDefaultEngine()` already triggers and
which uses a background `URLSession` on iOS. That path is untouched and always available, so a
user is never stuck.

`BackgroundAssetsModelInstaller.startForegroundDownload(...)` is also implemented and verified: it
drives the same files through `BADownloadManager.startForegroundDownload` in the foreground,
staging + installing each as it lands, for an explicit user-initiated "download now". It is **not**
auto-invoked in the launch path — racing it against WhisperKit's own downloader would fetch the
model twice — so WhisperKit's download stays the single runtime fallback while this remains a
ready capability for a future UI affordance (and the touch-the-pipeline change to make Background
Assets the sole downloader is deliberately out of scope).

## What the gates cover, and what only the App Store install flow can fire

**Covered by the build and the suite:** the extension builds and embeds into the app's
`Extensions/` folder with the correct extension-point identifier and no `NSExtension` dict; every
`BA*` Info.plist key lands in the built product; `BackgroundAssetsManifestTests` pins the pure core
— HuggingFace-URL construction from a relative path, the install/staging/download-base path
mapping, the pending-asset planner, and that the committed manifest describes the real 24-file
model exactly (per-file sizes and total). The launch-time `installStagedModel()` relocation is
plain filesystem moves, exercisable by dropping files into the App Group staging directory.

**Only an App Store / TestFlight install can fire** the system waking the extension *before first
launch*, and the periodic background re-checks: those are driven by the OS install pipeline, which
never runs for `xcodebuild install` or a dev-signed sideload. The code is complete and embedded;
only the trigger needs the Store path.

## Ship-time steps (turn it on)

1. **Host the manifest.** Publish `Sources/BackgroundAssetsKit/Resources/whisperkit-model-manifest.json`
   at the `BAManifestURL` (currently the placeholder
   `https://assets.fct-technologies.com/transcriptionstudio/whisperkit-model-manifest.json`). Point
   `BAManifestURL` at the real hosted URL if it differs.
2. **Verify the HuggingFace CDN domains.** `resolve/main/...weight.bin` (LFS files) 302-redirect to
   a HuggingFace CDN host. Confirm the actual redirect target and ensure `BADownloadDomainAllowList`
   covers it (currently `huggingface.co`, `*.huggingface.co`, `*.hf.co`, `*.cloudfront.net`).
3. **Re-add the entitlement and enable the capability.** Add
   ```xml
   <key>com.apple.developer.background-assets</key>
   <true/>
   ```
   to both `Sources/App/TranscriptionStudio.entitlements` (the iOS set) and
   `Sources/BackgroundAssetsExtension/BackgroundAssetsExtension.entitlements`, enable the
   **Background Assets** capability on the App ID in the Developer portal, and set a real
   `DEVELOPMENT_TEAM` so automatic signing can register it and the App Group. Everything else —
   the extension, the manifest, the `BA*` Info.plist keys — stays as-is.
4. **Regenerate if the model changes.** Run `scripts/gen-ba-manifest.sh` to rebuild the manifest
   from a fresh on-disk model, and update `BAMaxInstallSize` / `BADownloadAllowance` to match the
   new total.
