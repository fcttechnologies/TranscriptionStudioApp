import Foundation

enum IngestDropBoxError: LocalizedError, Sendable {
    /// The App Group container isn't reachable — the entitlement is missing or the group
    /// isn't provisioned. Surfaces so the extension can fail visibly rather than silently drop.
    case noContainer
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .noContainer:
            "The shared App Group container isn't available."
        case let .copyFailed(message):
            "Couldn't stage the shared file: \(message)"
        }
    }
}

/// The App Group drop-box: a Share extension **stages** a pending item here (a JSON manifest,
/// plus the media bytes for a file), then pings the host via the custom URL scheme; the host
/// **drains** the box, enqueues each item as a real transcription job, and **removes** it.
///
/// The container is injectable so the pure staging/draining logic is unit-testable in a plain
/// `swift test` process (which has no real App Group container).
enum IngestDropBox {
    /// Manifests live directly under this dir; staged media bytes under its `files/` subdir.
    private static let rootName = "PendingIngest"
    private static let filesName = "files"

    private static func rootURL(container: URL) -> URL {
        container.appendingPathComponent(rootName, isDirectory: true)
    }

    private static func filesURL(container: URL) -> URL {
        rootURL(container: container).appendingPathComponent(filesName, isDirectory: true)
    }

    private static func resolveContainer(_ container: URL?) throws -> URL {
        guard let container = container ?? AppGroup.containerURL else {
            throw IngestDropBoxError.noContainer
        }
        return container
    }

    // MARK: Stage (extension side)

    /// Copy a shared media file's bytes into the drop-box and write its manifest. Returns the
    /// staged item. `sourceURL` need only be valid for the duration of this call (matches
    /// `NSItemProvider.loadFileRepresentation`'s temp-file contract).
    @discardableResult
    static func stageFile(from sourceURL: URL,
                                 title: String,
                                 container: URL? = nil) throws -> PendingIngest {
        let container = try resolveContainer(container)
        let filesDir = filesURL(container: container)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let stagedFilename = "\(id.uuidString).\(ext)"
        let destination = filesDir.appendingPathComponent(stagedFilename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw IngestDropBoxError.copyFailed(error.localizedDescription)
        }

        let item = PendingIngest(id: id, kind: .file, title: title, stagedFilename: stagedFilename)
        try writeManifest(item, container: container)
        return item
    }

    /// Write the manifest for a shared web URL (no bytes to stage).
    @discardableResult
    static func stageURL(_ urlString: String,
                                title: String,
                                container: URL? = nil) throws -> PendingIngest {
        let container = try resolveContainer(container)
        let item = PendingIngest(id: UUID(), kind: .url, title: title, urlString: urlString)
        try writeManifest(item, container: container)
        return item
    }

    private static func writeManifest(_ item: PendingIngest, container: URL) throws {
        let root = rootURL(container: container)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Default `Date` coding (raw timeIntervalSinceReferenceDate) round-trips losslessly, so a
        // drained item equals the staged one exactly.
        let data = try JSONEncoder().encode(item)
        try data.write(to: manifestURL(for: item.id, container: container), options: .atomic)
    }

    private static func manifestURL(for id: UUID, container: URL) -> URL {
        rootURL(container: container).appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Drain (host side)

    /// Every staged item, oldest first. Undecodable manifests are skipped (never throws — a
    /// corrupt entry must not block the rest of the queue).
    static func drain(container: URL? = nil) -> [PendingIngest] {
        guard let container = (try? resolveContainer(container)) else { return [] }
        let root = rootURL(container: container)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(PendingIngest.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The absolute URL of a `.file` item's staged bytes (nil for a `.url` item).
    static func stagedFileURL(for item: PendingIngest, container: URL? = nil) -> URL? {
        guard let stagedFilename = item.stagedFilename,
              let container = try? resolveContainer(container) else { return nil }
        return filesURL(container: container).appendingPathComponent(stagedFilename)
    }

    /// Delete an item's manifest and (for a file) its staged bytes. Idempotent.
    static func remove(_ item: PendingIngest, container: URL? = nil) {
        guard let container = try? resolveContainer(container) else { return }
        try? FileManager.default.removeItem(at: manifestURL(for: item.id, container: container))
        if let staged = stagedFileURL(for: item, container: container) {
            try? FileManager.default.removeItem(at: staged)
        }
    }
}
