import Foundation

/// A model actually present on disk, with its resolved on-disk footprint. Backs the Settings
/// "Storage" section: the source of truth for what's really downloaded and how much space it
/// costs.
struct StoredModel: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case speech(SpeechModel)
        case speechSynthesis
    }

    let kind: Kind
    /// The exact on-disk paths owned by this model. Deletion removes precisely these, never a
    /// shared parent directory that might hold sibling files.
    let paths: [URL]
    let bytes: Int64

    var id: String {
        switch kind {
        case .speech(let model): "speech.\(model.rawValue)"
        case .speechSynthesis: "tts"
        }
    }

    var displayName: String {
        switch kind {
        case .speech(let model): model.displayName
        case .speechSynthesis: "Qwen3 TTS"
        }
    }

    var detail: String {
        switch kind {
        case .speech(let model): model.detail
        case .speechSynthesis: "Speech synthesis"
        }
    }
}

/// Scans the on-disk model caches — the speech models' root and the synthesis engine's — and
/// reports what's actually present, with its real size. Pure filesystem inspection; no network.
enum ModelStorageScanner {
    /// Every model present on disk right now, largest first.
    static func scan(speechRoot: URL = SpeechModel.root(),
                     speechSynthesisRoot: URL = TTSKitTtsEngine.defaultDownloadBase()) -> [StoredModel] {
        (scanSpeechModels(root: speechRoot) + scanSpeechSynthesisModel(root: speechSynthesisRoot))
            .sorted { $0.bytes > $1.bytes }
    }

    /// Deletes every path a model owns. Best-effort per path — one already-missing file (a
    /// concurrent delete, a partial prior cleanup) doesn't block removing the rest — but still
    /// surfaces the last failure so the caller can report it.
    static func delete(_ model: StoredModel) throws {
        var lastError: Error?
        for path in model.paths {
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
    }

    // MARK: - Speech models

    /// `<root>/<model>/` for each of the three speech models: the directory is the model's whole
    /// footprint, so deletion owns it. An empty or partial directory still counts by its bytes;
    /// `SpeechModelStore.isInstalled` is the question of whether it is usable.
    static func scanSpeechModels(root: URL) -> [StoredModel] {
        SpeechModel.allCases.compactMap { model in
            let directory = model.directory(under: root)
            let bytes = pathSize(directory)
            guard bytes > 0 else { return nil }
            return StoredModel(kind: .speech(model), paths: [directory], bytes: bytes)
        }
    }

    // MARK: - Speech synthesis (TTSKit)

    /// The synthesis engine's download base (`…/Models/ttskit`) — the CoreML weights, the
    /// tokenizer, and the Hub client's bookkeeping. Everything under this root exists solely
    /// for synthesis, so the root itself is the model's exact footprint and deletion owns the
    /// whole directory.
    static func scanSpeechSynthesisModel(root: URL) -> [StoredModel] {
        let bytes = pathSize(root)
        guard bytes > 0 else { return [] }
        return [StoredModel(kind: .speechSynthesis, paths: [root], bytes: bytes)]
    }

    // MARK: - Sizing

    /// The on-disk footprint of a file OR a directory (recursive).
    static func pathSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return 0 }
        return values.isDirectory == true ? directorySize(url) : fileSize(url)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [], errorHandler: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return 0 }
        return Int64(size)
    }
}
