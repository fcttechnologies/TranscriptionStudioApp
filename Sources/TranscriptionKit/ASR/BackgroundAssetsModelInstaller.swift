#if os(iOS)
@preconcurrency import BackgroundAssets
import BackgroundAssetsKit
import Foundation
import OSLog
import ShareKit

/// The app side of the Background Assets model pipeline. Its two jobs:
///
/// 1. **Install** — at launch, relocate whatever the downloader extension staged in the App
///    Group into WhisperKit's download base, so `WhisperKitAsrEngine.prepare()` finds the model
///    and skips the network. The extension can't write to the app's own Application Support
///    (that container isn't shared), so it parks files in the App Group and the app moves them
///    the last hop. Idempotent and cheap — safe on every launch.
/// 2. **Foreground fallback** — if the app opens with the model absent (the extension never ran,
///    or the download is incomplete), `startForegroundDownload` drives the same downloads through
///    `BADownloadManager` in the foreground, staging + installing each file as it lands.
///
/// The pure planning (which files still need downloading) lives in `WhisperKitModelLayout`; this
/// type is only the filesystem + `BADownloadManager` wiring around it.
public enum BackgroundAssetsModelInstaller {

    /// Relocate every file the extension staged in the App Group into `downloadBase`, preserving
    /// the `models/<repo>/<variant>/…` layout. Files already present at `downloadBase` with the
    /// same size are left alone (idempotent). Returns the number of files moved.
    ///
    /// Enumerates fully *before* moving so relocating a file can't disturb the live enumeration.
    @discardableResult
    public static func installStagedModel(
        appGroupContainer: URL? = AppGroup.containerURL,
        downloadBase: URL = WhisperKitAsrEngine.defaultDownloadBase()
    ) -> Int {
        guard let container = appGroupContainer else { return 0 }
        let stagingRoot = WhisperKitModelLayout.stagingRoot(appGroupContainer: container)
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagingRoot.path) else { return 0 }

        let stagedFiles = regularFiles(under: stagingRoot)
        guard !stagedFiles.isEmpty else { return 0 }

        var installed = 0
        for fileURL in stagedFiles {
            let relative = relativePath(of: fileURL, under: stagingRoot)
            let dest = downloadBase.appendingPathComponent(relative)
            if fileSize(dest) == fileSize(fileURL) { // already installed identically
                try? fm.removeItem(at: fileURL)
                continue
            }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: fileURL, to: dest)
                installed += 1
            } catch {
                Logger.backgroundAssets.error("Install failed for a staged model file: \(error, privacy: .public)")
            }
        }
        if installed > 0 {
            Logger.backgroundAssets.info("Installed \(installed, privacy: .public) staged model files into the download base")
        }
        return installed
    }

    /// True when every file in the bundled manifest is present in `downloadBase` at its exact
    /// size — i.e. WhisperKit will load without downloading anything.
    public static func isModelInstalled(
        downloadBase: URL = WhisperKitAsrEngine.defaultDownloadBase()
    ) -> Bool {
        guard let manifest = try? WhisperKitModelManifest.bundled() else { return false }
        return manifest.assets.allSatisfy { asset in
            let installPath = WhisperKitModelLayout.installRelativePath(
                repo: manifest.repo, variant: manifest.variant, relativePath: asset.path)
            let url = WhisperKitModelLayout.installedURL(downloadBase: downloadBase, installRelativePath: installPath)
            return fileSize(url) == asset.size
        }
    }

    /// Foreground-download every model file that isn't already present, via `BADownloadManager`,
    /// staging + installing each as it finishes. Use this for an explicit, user-initiated
    /// "download now" — e.g. a first launch where the extension never got to run (Background
    /// Assets fires the extension only for App Store installs/updates, not sideloaded builds).
    ///
    /// Returns immediately after scheduling; `onProgress` reports installed/total file counts and
    /// `onComplete` fires once every file is installed (or with the first error). The heavy model
    /// I/O is the system's; this object only reacts to its delegate callbacks.
    ///
    /// This is a genuine alternative to WhisperKit's own downloader, not a wrapper of it. In the
    /// normal launch path the app instead relies on `installStagedModel` (extension pre-download)
    /// plus WhisperKit's built-in background-session download as the guaranteed fallback, so this
    /// is not auto-invoked — wiring both downloaders into the same hot path would fetch the model
    /// twice. See Documentation/BACKGROUND-ASSETS.md.
    @discardableResult
    public static func startForegroundDownload(
        appGroupContainer: URL? = AppGroup.containerURL,
        downloadBase: URL = WhisperKitAsrEngine.defaultDownloadBase(),
        onProgress: (@Sendable (_ installed: Int, _ total: Int) -> Void)? = nil,
        onComplete: (@Sendable (Result<Void, Error>) -> Void)? = nil
    ) -> ForegroundDownloadSession? {
        guard let container = appGroupContainer else {
            onComplete?(.failure(BackgroundAssetsInstallerError.noAppGroupContainer))
            return nil
        }
        let manifest: WhisperKitModelManifest
        do {
            manifest = try WhisperKitModelManifest.bundled()
        } catch {
            onComplete?(.failure(error))
            return nil
        }
        let session = ForegroundDownloadSession(
            manifest: manifest, appGroupContainer: container, downloadBase: downloadBase,
            onProgress: onProgress, onComplete: onComplete)
        session.start()
        return session
    }

    // MARK: - Filesystem helpers

    private static func regularFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }
}

public enum BackgroundAssetsInstallerError: LocalizedError, Sendable {
    case noAppGroupContainer

    public var errorDescription: String? {
        switch self {
        case .noAppGroupContainer:
            "The app group container isn't available, so the speech model can't be staged."
        }
    }
}

/// Drives a set of `BADownloadManager` foreground downloads to completion and installs each
/// finished file. Owned by the caller for the duration of the download; released once complete.
/// `@unchecked Sendable`: mutable progress state is confined behind `stateLock`.
public final class ForegroundDownloadSession: NSObject, BADownloadManagerDelegate, @unchecked Sendable {
    private let manifest: WhisperKitModelManifest
    private let appGroupContainer: URL
    private let downloadBase: URL
    private let onProgress: (@Sendable (Int, Int) -> Void)?
    private let onComplete: (@Sendable (Result<Void, Error>) -> Void)?

    private let stateLock = NSLock()
    private var remaining = 0
    private var total = 0
    private var finished = false

    init(manifest: WhisperKitModelManifest, appGroupContainer: URL, downloadBase: URL,
         onProgress: (@Sendable (Int, Int) -> Void)?, onComplete: (@Sendable (Result<Void, Error>) -> Void)?) {
        self.manifest = manifest
        self.appGroupContainer = appGroupContainer
        self.downloadBase = downloadBase
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func start() {
        let pending = WhisperKitModelLayout.pendingAssets(
            manifest: manifest, downloadBase: downloadBase, appGroupContainer: appGroupContainer,
            sizeAt: { BackgroundAssetsModelInstaller.fileSize($0) })

        // Relocate anything already staged, then re-check: the model may be complete already.
        BackgroundAssetsModelInstaller.installStagedModel(
            appGroupContainer: appGroupContainer, downloadBase: downloadBase)

        guard !pending.isEmpty else {
            finish(.success(()))
            return
        }

        stateLock.lock()
        total = pending.count
        remaining = pending.count
        stateLock.unlock()

        let manager = BADownloadManager.shared
        manager.delegate = self
        manager.withExclusiveControl { [weak self] _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            for asset in pending {
                let installPath = WhisperKitModelLayout.installRelativePath(
                    repo: self.manifest.repo, variant: self.manifest.variant, relativePath: asset.path)
                guard let url = WhisperKitModelLayout.downloadURL(
                    repo: self.manifest.repo, variant: self.manifest.variant, relativePath: asset.path) else { continue }
                let download = BAURLDownload(
                    identifier: installPath,
                    request: URLRequest(url: url),
                    essential: false,
                    fileSize: asset.size,
                    applicationGroupIdentifier: AppGroup.identifier,
                    priority: .default)
                do {
                    try BADownloadManager.shared.startForegroundDownload(download)
                } catch {
                    self.finish(.failure(error))
                    return
                }
            }
        }
    }

    // MARK: - BADownloadManagerDelegate

    public func download(_ download: BADownload, finishedWithFileURL fileURL: URL) {
        let dest = WhisperKitModelLayout.installedURL(downloadBase: downloadBase, installRelativePath: download.identifier)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: fileURL, to: dest)
        } catch {
            Logger.backgroundAssets.error("Foreground install failed: \(error, privacy: .public)")
        }

        stateLock.lock()
        remaining -= 1
        let done = remaining
        let all = total
        stateLock.unlock()
        onProgress?(all - done, all)
        if done <= 0 { finish(.success(())) }
    }

    public func download(_ download: BADownload, failedWithError error: Error) {
        Logger.backgroundAssets.error("Foreground download failed: \(error, privacy: .public)")
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        stateLock.lock()
        if finished { stateLock.unlock(); return }
        finished = true
        stateLock.unlock()
        BADownloadManager.shared.delegate = nil
        onComplete?(result)
    }
}
#endif
