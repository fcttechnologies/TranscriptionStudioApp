import Foundation
import Observation
import OSLog

/// The speech models, fetched by the system in the background from the moment the app first
/// launches: every file still missing under the models root becomes one download task in a
/// background `URLSession`, which keeps transferring while the app is suspended and resumes
/// after the app is terminated and relaunched. The app's part is small: name the missing files
/// at launch, move each finished file into place, and say how far along the whole set is.
///
/// Nothing here asks. The front door shows this progress instead of an offer while the door is
/// still closed, and the engines' own `prepare()` waits on a model this session is already
/// fetching rather than fetching it twice. Wi-Fi only: a gigabyte over cellular is not a thing
/// to start unasked; a job the person starts on cellular takes the store's on-demand path.
@MainActor
@Observable
final class SpeechModelDownloader {
    static let shared = SpeechModelDownloader()

    /// The whole set, as one number: bytes on disk over bytes in the manifest.
    enum State: Equatable, Sendable {
        case idle
        case downloading(fraction: Double)
        case complete
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Models whose every file is on disk, updated as files land.
    private(set) var installed: Set<SpeechModel> = []

    private let manifest: ModelManifest
    private let root: URL
    private let session: URLSession
    private let bridge: Bridge
    private let totalBytes: Int
    private var receivedByPath: [String: Int] = [:]
    private var waiters: [SpeechModel: [CheckedContinuation<Void, Error>]] = [:]

    static let sessionIdentifier = "com.fcttechnologies.TranscriptionStudio.speech-models"

    init(manifest: ModelManifest = .shipped, root: URL = SpeechModel.root(),
         sessionIdentifier: String = SpeechModelDownloader.sessionIdentifier) {
        self.manifest = manifest
        self.root = root
        self.totalBytes = manifest.totalSize
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.allowsCellularAccess = false
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        let bridge = Bridge()
        self.bridge = bridge
        self.session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil)
        bridge.owner = self
        refreshInstalled()
    }

    /// Schedule every file still missing, once. Files already on disk at their exact size and
    /// files the session is already transferring (a relaunch mid-download) are left alone.
    /// Idempotent; called at every launch.
    func start() {
        Task { await scheduleMissing() }
    }

    /// The system relaunched the app for this session's events; the handler is called once the
    /// session reports it has delivered them.
    func handleEvents(completion: @escaping @Sendable () -> Void) {
        bridge.eventsCompletion = completion
    }

    /// Wait for `model` if this session is fetching it; returns at once when it is installed,
    /// and throws when it is neither, so the caller fetches it on demand.
    func waitForModel(_ model: SpeechModel) async throws {
        if SpeechModelStore.isInstalled(model, manifest: manifest, root: root) { return }
        let inFlight = await session.allTasks.contains { ($0.taskDescription ?? "").hasPrefix(model.rawValue + "/") }
        guard inFlight else { throw SpeechModelDownloaderError.notInFlight(model) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters[model, default: []].append(c)
        }
    }

    // MARK: - Scheduling

    private func scheduleMissing() async {
        let pending = ModelLayout.pendingAssets(manifest.assets, root: root, appGroupContainer: nil,
                                                sizeAt: SpeechModelStore.fileSize)
        let inFlight = Set(await session.allTasks.compactMap(\.taskDescription))
        let onDisk = manifest.assets.filter { !pending.contains($0) }.reduce(0) { $0 + $1.size }
        receivedByPath = [:]
        if pending.isEmpty {
            state = .complete
            refreshInstalled()
            return
        }
        for asset in pending where !inFlight.contains(asset.path) {
            guard let url = ModelLayout.downloadURL(repo: manifest.repo, path: asset.path) else { continue }
            let task = session.downloadTask(with: url)
            task.taskDescription = asset.path
            task.countOfBytesClientExpectsToReceive = Int64(asset.size)
            task.resume()
        }
        state = .downloading(fraction: totalBytes == 0 ? 0 : Double(onDisk) / Double(totalBytes))
        Logger.backgroundAssets.info("Speech models: \(pending.count, privacy: .public) files to fetch, \(inFlight.count, privacy: .public) already in flight")
    }

    private func refreshInstalled() {
        installed = Set(SpeechModel.allCases.filter { SpeechModelStore.isInstalled($0, manifest: manifest, root: root) })
    }

    // MARK: - Delegate events, on the main actor (driven directly by the tests)

    func progressed(path: String, received: Int) {
        receivedByPath[path] = received
        publishProgress()
    }

    func finished(path: String, temporary: URL) {
        guard let asset = manifest.assets.first(where: { $0.path == path }) else { return }
        let fm = FileManager.default
        do {
            guard SpeechModelStore.fileSize(temporary) == asset.size else {
                throw SpeechModelStoreError.sizeMismatch(path, expected: asset.size, got: SpeechModelStore.fileSize(temporary) ?? 0)
            }
            let dest = ModelLayout.installedURL(root: root, path: path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: temporary, to: dest)
        } catch {
            Logger.backgroundAssets.error("Speech model file \(path, privacy: .public) failed to land: \(error, privacy: .public)")
            failed(path: path, error: error)
            return
        }
        receivedByPath[path] = asset.size
        let before = installed
        refreshInstalled()
        for model in installed.subtracting(before) {
            waiters.removeValue(forKey: model)?.forEach { $0.resume() }
        }
        publishProgress()
    }

    func failed(path: String, error: Error) {
        state = .failed(error.localizedDescription)
        if let model = ModelAsset(path: path, size: 0).model {
            waiters.removeValue(forKey: model)?.forEach { $0.resume(throwing: error) }
        }
    }

    private func publishProgress() {
        guard totalBytes > 0 else { return }
        let onDisk = manifest.assets.filter { SpeechModelStore.fileSize(ModelLayout.installedURL(root: root, path: $0.path)) == $0.size }
        let landed = Set(onDisk.map(\.path))
        let received = onDisk.reduce(0) { $0 + $1.size }
            + receivedByPath.filter { !landed.contains($0.key) }.values.reduce(0, +)
        let fraction = min(1, Double(received) / Double(totalBytes))
        if installed.count == SpeechModel.allCases.count {
            state = .complete
        } else if case .failed = state {
            return
        } else {
            state = .downloading(fraction: fraction)
        }
    }

    /// The `URLSessionDownloadDelegate`, off the main actor; every event hops onto the owner.
    private final class Bridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var owner: SpeechModelDownloader?
        var eventsCompletion: (@Sendable () -> Void)?

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let path = downloadTask.taskDescription else { return }
            // The temporary file is deleted when this returns, so it moves synchronously here.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do { try FileManager.default.moveItem(at: location, to: keep) } catch { return }
            Task { @MainActor [owner] in owner?.finished(path: path, temporary: keep) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let path = downloadTask.taskDescription else { return }
            let received = Int(totalBytesWritten)
            Task { @MainActor [owner] in owner?.progressed(path: path, received: received) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let path = task.taskDescription else { return }
            Task { @MainActor [owner] in owner?.failed(path: path, error: error) }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            let completion = eventsCompletion
            eventsCompletion = nil
            Task { @MainActor in completion?() }
        }
    }
}

enum SpeechModelDownloaderError: LocalizedError {
    case notInFlight(SpeechModel)
    var errorDescription: String? {
        switch self {
        case .notInFlight(let model): "The \(model.displayName) model isn't being downloaded in the background."
        }
    }
}
