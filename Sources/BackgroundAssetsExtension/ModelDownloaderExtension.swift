import BackgroundAssets
import ExtensionFoundation
import Foundation
import OSLog

/// The Background Assets downloader extension. The system launches it — before the app's first
/// launch and periodically after — with the on-disk location of the app's manifest (fetched via
/// the app's `BAManifestURL` Info.plist key). It parses the manifest and hands the system the
/// speech model files still needed as **non-essential** downloads, then stages each finished
/// file into the App Group for the app to install on launch.
///
/// The extension runs in a tight, short-lived sandbox: keep every callback fast and side-effect
/// light (parse + return; move a file). No engine here — only the manifest, the path math and
/// Foundation, so the extension stays well under its memory budget.
@main
struct ModelDownloaderExtension: BADownloaderExtension {
    private let log = Logger(subsystem: "com.fcttechnologies.TranscriptionStudio",
                             category: "background-assets-extension")

    init() {}

    /// The model files that still need downloading. Non-essential (the app is fully usable while
    /// they download; an engine fetches what it needs on first use if they aren't ready yet), so
    /// they don't gate the app's launch. Files already staged at the correct size are skipped, so
    /// periodic re-invocations only fetch what's missing.
    func downloads(for request: BAContentRequest,
                   manifestURL: URL,
                   extensionInfo: BAAppExtensionInfo) -> Set<BADownload> {
        guard let container = AppGroup.containerURL else {
            log.error("No App Group container — cannot schedule model downloads")
            return []
        }
        let manifest: ModelManifest
        do {
            manifest = try ModelManifest.load(contentsOf: manifestURL)
        } catch {
            log.error("Failed to parse manifest: \(error, privacy: .public)")
            return []
        }

        var downloads: Set<BADownload> = []
        for asset in manifest.assets {
            let staged = ModelLayout.stagedURL(appGroupContainer: container, path: asset.path)
            if fileSize(staged) == asset.size { continue }
            guard let url = ModelLayout.downloadURL(repo: manifest.repo, path: asset.path) else { continue }
            downloads.insert(BAURLDownload(
                identifier: asset.path,
                request: URLRequest(url: url),
                essential: false,
                fileSize: asset.size,
                applicationGroupIdentifier: AppGroup.identifier,
                priority: .default))
        }
        log.info("Scheduling \(downloads.count, privacy: .public) speech model downloads")
        return downloads
    }

    /// Stage a finished file into the App Group at its `<model>/<relpath>` location. The
    /// download's identifier IS that relative path, so the destination is recovered directly.
    /// The app relocates the staged tree into the models root on launch.
    func backgroundDownload(_ finishedDownload: BADownload, finishedWithFileURL fileURL: URL) {
        guard let container = AppGroup.containerURL else { return }
        let dest = ModelLayout.stagedURL(appGroupContainer: container, path: finishedDownload.identifier)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: fileURL, to: dest)
        } catch {
            log.error("Failed to stage a finished download: \(error, privacy: .public)")
        }
    }

    func backgroundDownload(_ failedDownload: BADownload, failedWithError error: Error) {
        log.error("Download failed for \(failedDownload.identifier, privacy: .public): \(error, privacy: .public)")
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
