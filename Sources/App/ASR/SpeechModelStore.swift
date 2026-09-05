import Foundation
import OSLog

/// The speech models on disk: what is installed, what the downloader extension staged, and the
/// download that fills in whatever is missing. Every engine's `prepare()` goes through
/// `ensureInstalled` before it loads, so a model that is not there yet is fetched then, exactly
/// as a model the extension pre-fetched is found already present.
///
/// Three jobs:
/// 1. **Install** — at launch, relocate whatever the downloader extension staged in the App
///    Group into the models root. The extension can't write to the app's own Application
///    Support (that container isn't shared), so it parks files in the App Group and the app
///    moves them the last hop. Idempotent and cheap: safe on every launch.
/// 2. **Check** — every file of a model present at its exact manifest size.
/// 3. **Download on demand** — the files still missing, one `URLSession` download task each,
///    verified to the manifest's byte size before they land, on whatever network the person is on
///    (they asked for a job). Progress is by bytes across the whole model. A download interrupted
///    partway leaves the finished files in place and re-fetches only what is still missing next
///    time. `SpeechModelDownloader` is the other route to the same files: the background session
///    that starts at launch and keeps going while the app is away; an engine preparing a model
///    that session is already fetching waits for it here rather than fetching it twice.
///
/// The pure planning (which files still need downloading) lives in `ModelLayout`; this type is
/// the filesystem and network wiring around it.
enum SpeechModelStore {

    /// Relocate every file the extension staged in the App Group into `root`, preserving the
    /// `<model>/<relpath>` layout. Files already present at `root` with the same size are left
    /// alone. Returns the number of files moved. Enumerates fully *before* moving so relocating a
    /// file can't disturb the live enumeration.
    @discardableResult
    static func installStagedModels(
        appGroupContainer: URL? = AppGroup.containerURL,
        root: URL = SpeechModel.root()
    ) -> Int {
        guard let container = appGroupContainer else { return 0 }
        let stagingRoot = ModelLayout.stagingRoot(appGroupContainer: container)
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagingRoot.path) else { return 0 }

        let stagedFiles = regularFiles(under: stagingRoot)
        guard !stagedFiles.isEmpty else { return 0 }

        var installed = 0
        for fileURL in stagedFiles {
            let relative = relativePath(of: fileURL, under: stagingRoot)
            let dest = ModelLayout.installedURL(root: root, path: relative)
            if fileSize(dest) == fileSize(fileURL) {
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
            Logger.backgroundAssets.info("Installed \(installed, privacy: .public) staged model files")
        }
        return installed
    }

    /// True when every file of `model` in the manifest is present under `root` at its exact size.
    static func isInstalled(
        _ model: SpeechModel,
        manifest: ModelManifest? = .shipped,
        root: URL = SpeechModel.root()
    ) -> Bool {
        guard let manifest else { return false }
        let assets = manifest.assets(of: model)
        guard !assets.isEmpty else { return false }
        return assets.allSatisfy { fileSize(ModelLayout.installedURL(root: root, path: $0.path)) == $0.size }
    }

    /// Download and install whatever of `model` is still missing. Returns at once when nothing
    /// is. `onProgress` reports the fraction of the model's bytes on disk.
    static func ensureInstalled(
        _ model: SpeechModel,
        manifest: ModelManifest? = .shipped,
        root: URL = SpeechModel.root(),
        appGroupContainer: URL? = AppGroup.containerURL,
        session: URLSession = .shared,
        waitInFlight: @escaping @Sendable (SpeechModel) async throws -> Void = { try await SpeechModelDownloader.shared.waitForModel($0) },
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let manifest else { throw SpeechModelStoreError.noManifest }
        let assets = manifest.assets(of: model)
        guard !assets.isEmpty else { throw SpeechModelStoreError.notInManifest(model) }
        installStagedModels(appGroupContainer: appGroupContainer, root: root)
        // The background session may already be fetching this model (it starts at launch): wait
        // for it rather than pulling the same bytes twice. It throws when the model is neither
        // installed nor in flight, and this path fetches on demand.
        if (try? await waitInFlight(model)) != nil, isInstalled(model, manifest: manifest, root: root) {
            onProgress(1)
            return
        }
        let pending = ModelLayout.pendingAssets(assets, root: root, appGroupContainer: nil, sizeAt: fileSize)
        let total = assets.reduce(0) { $0 + $1.size }
        var done = total - pending.reduce(0) { $0 + $1.size }
        onProgress(total == 0 ? 1 : Double(done) / Double(total))
        for asset in pending {
            guard let url = ModelLayout.downloadURL(repo: manifest.repo, path: asset.path) else {
                throw SpeechModelStoreError.badPath(asset.path)
            }
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SpeechModelStoreError.httpStatus(http.statusCode, asset.path)
            }
            guard fileSize(temporary) == asset.size else {
                throw SpeechModelStoreError.sizeMismatch(asset.path, expected: asset.size, got: fileSize(temporary) ?? 0)
            }
            let dest = ModelLayout.installedURL(root: root, path: asset.path)
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: temporary, to: dest)
            done += asset.size
            onProgress(Double(done) / Double(total))
        }
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

    /// `url`'s path below `root`, by components with both sides' symlinks resolved, so a root
    /// spelled `/var/…` still matches an enumeration that comes back as `/private/var/…`.
    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootParts = root.resolvingSymlinksInPath().pathComponents
        let parts = url.resolvingSymlinksInPath().pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
            return url.lastPathComponent
        }
        return parts.dropFirst(rootParts.count).joined(separator: "/")
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}

/// How an engine gets its model onto disk before loading it: the store's download by default,
/// a no-op or a failure in tests. Progress is the fraction of the model's bytes present.
typealias SpeechModelInstaller = @Sendable (SpeechModel, @escaping @Sendable (Double) -> Void) async throws -> Void

extension SpeechModel {
    static let install: SpeechModelInstaller = { model, onProgress in
        try await SpeechModelStore.ensureInstalled(model, onProgress: onProgress)
    }
}

enum SpeechModelStoreError: LocalizedError, Sendable, Equatable {
    case noManifest
    case notInManifest(SpeechModel)
    case badPath(String)
    case httpStatus(Int, String)
    case sizeMismatch(String, expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .noManifest:
            "The speech model manifest is missing from the app."
        case .notInManifest(let model):
            "The \(model.displayName) model isn't listed in the app's manifest."
        case .badPath(let path):
            "The model file path \(path) can't be turned into a download URL."
        case .httpStatus(let code, let path):
            "Downloading \(path) failed with HTTP \(code)."
        case .sizeMismatch(let path, let expected, let got):
            "Downloaded \(path) was \(got) bytes; expected \(expected)."
        }
    }
}
