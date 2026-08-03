import Foundation

/// A speech model actually present on disk, with its resolved on-disk footprint. Backs the
/// Settings "Storage" section — the settings picker only names a *preference* (`AppSettings`),
/// this is the source of truth for what's really downloaded and how much space it costs.
public struct StoredModel: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case whisper(AppSettings.WhisperModel)
        case diarizer
        case speechSynthesis
    }

    public let kind: Kind
    /// The exact on-disk paths owned by this model. Deletion removes precisely these, never a
    /// shared parent directory that might hold sibling files (e.g. the Sortformer store's root
    /// also holds `metadata.json`/the manifest, which aren't part of any one model's footprint).
    public let paths: [URL]
    public let bytes: Int64

    public var id: String {
        switch kind {
        case .whisper(let model): "whisper.\(model.rawValue)"
        case .diarizer: "diarizer"
        case .speechSynthesis: "tts"
        }
    }

    public var displayName: String {
        switch kind {
        case .whisper(let model): model.displayName
        case .diarizer: "Streaming Sortformer"
        case .speechSynthesis: "Qwen3 TTS"
        }
    }

    public var detail: String {
        switch kind {
        case .whisper: "Speech recognition"
        case .diarizer: "Speaker diarization"
        case .speechSynthesis: "Speech synthesis"
        }
    }
}

/// Scans the on-disk model caches — WhisperKit's download base and the Sortformer store — and
/// reports what's actually present, with its real size. Pure filesystem inspection; no network.
public enum ModelStorageScanner {
    /// Every model variant present on disk right now, largest first.
    public static func scan(whisperKitDownloadBase: URL = WhisperKitAsrEngine.defaultDownloadBase(),
                            sortformerRoot: URL = SortformerModelStore().root,
                            speechSynthesisRoot: URL = TTSKitTtsEngine.defaultDownloadBase()) -> [StoredModel] {
        (scanWhisperKitModels(downloadBase: whisperKitDownloadBase)
            + scanSortformerModel(root: sortformerRoot)
            + scanSpeechSynthesisModel(root: speechSynthesisRoot))
            .sorted { $0.bytes > $1.bytes }
    }

    /// Deletes every path a model owns. Best-effort per path — one already-missing file (a
    /// concurrent delete, a partial prior cleanup) doesn't block removing the rest — but still
    /// surfaces the last failure so the caller can report it.
    public static func delete(_ model: StoredModel) throws {
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

    // MARK: - WhisperKit

    /// `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>` — one directory per
    /// downloaded variant (the layout `WhisperKit.download` lays down; see
    /// `WhisperKitAsrEngine.defaultDownloadBase`). `.cache` is WhisperKit/Hugging Face's own
    /// bookkeeping alongside the variants, not a model — it's excluded by simply not matching
    /// any known variant name below.
    static func scanWhisperKitModels(downloadBase: URL) -> [StoredModel] {
        let repoDir = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: repoDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let model = AppSettings.WhisperModel.allCases.first(where: { $0.whisperKitVariant == url.lastPathComponent })
            else { return nil }
            let bytes = directorySize(url)
            guard bytes > 0 else { return nil }   // an empty/partial dir isn't a usable model
            return StoredModel(kind: .whisper(model), paths: [url], bytes: bytes)
        }
    }

    // MARK: - Sortformer diarizer

    /// The diarizer's own managed artifacts (`modelURL` + `melFiltersURL`) — never the whole
    /// store root, which also holds `metadata.json` and the manifest.
    static func scanSortformerModel(root: URL) -> [StoredModel] {
        let store = SortformerModelStore(root: root)
        guard store.hasLocalArtifacts else { return [] }
        let paths = [store.modelURL, store.melFiltersURL]
        let bytes = paths.reduce(Int64(0)) { $0 + pathSize($1) }
        guard bytes > 0 else { return [] }
        return [StoredModel(kind: .diarizer, paths: paths, bytes: bytes)]
    }

    // MARK: - Speech synthesis (TTSKit)

    /// The synthesis engine's download base (`…/Models/ttskit`) — the CoreML weights, the
    /// tokenizer, and the Hub client's bookkeeping. Everything under this root exists solely
    /// for synthesis (unlike the Sortformer store's root, which also holds shared metadata),
    /// so the root itself is the model's exact footprint and deletion owns the whole directory.
    static func scanSpeechSynthesisModel(root: URL) -> [StoredModel] {
        let bytes = pathSize(root)
        guard bytes > 0 else { return [] }
        return [StoredModel(kind: .speechSynthesis, paths: [root], bytes: bytes)]
    }

    // MARK: - Sizing

    /// The on-disk footprint of a file OR a directory (recursive).
    static func pathSize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        return isDirectory.boolValue ? directorySize(url) : fileSize(url)
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
