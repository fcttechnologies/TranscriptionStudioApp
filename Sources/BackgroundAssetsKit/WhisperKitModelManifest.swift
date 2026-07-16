import Foundation

/// One file in a WhisperKit model variant: its path relative to the variant directory and its
/// exact byte size. Background Assets requires the size to match the file the server delivers —
/// a mismatch fails the download — so these come from the real on-disk model, not an estimate.
public struct WhisperKitModelAsset: Codable, Sendable, Equatable, Hashable {
    /// Path within the variant directory, e.g. `AudioEncoder.mlmodelc/weights/weight.bin`.
    public let path: String
    /// Exact size in bytes.
    public let size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

/// The self-hosted Background Assets manifest for a WhisperKit speech model. The system
/// downloads this file (via the app's `BAManifestURL` Info.plist key) before it wakes the
/// downloader extension, then hands the extension the on-disk location; the extension parses
/// it to learn which files to schedule, their download URLs, and their sizes.
///
/// The manifest schema is the app's to define (Apple leaves the format entirely to you). This
/// is that schema — the minimum a WhisperKit variant needs: the HuggingFace repo, the variant
/// directory, and every file with its exact size.
public struct WhisperKitModelManifest: Codable, Sendable, Equatable {
    /// The HuggingFace repo the files resolve from, e.g. `argmaxinc/whisperkit-coreml`.
    public let repo: String
    /// The model variant directory, e.g. `openai_whisper-large-v3-v20240930_turbo`.
    public let variant: String
    /// Every file the variant is composed of, with exact byte sizes.
    public let assets: [WhisperKitModelAsset]

    public init(repo: String, variant: String, assets: [WhisperKitModelAsset]) {
        self.repo = repo
        self.variant = variant
        self.assets = assets
    }

    /// Total download size across all assets — the value the app declares in `BAMaxInstallSize`.
    public var totalSize: Int { assets.reduce(0) { $0 + $1.size } }

    public static func decode(from data: Data) throws -> WhisperKitModelManifest {
        try JSONDecoder().decode(WhisperKitModelManifest.self, from: data)
    }

    public static func load(contentsOf url: URL) throws -> WhisperKitModelManifest {
        try decode(from: Data(contentsOf: url))
    }

    /// The manifest bundled with the app/extension (a copy of the hosted file), used for the
    /// app-side completeness check and the foreground fallback. The extension itself parses the
    /// system-downloaded copy at its `manifestURL`, so a server update takes effect there without
    /// an app update.
    public static func bundled() throws -> WhisperKitModelManifest {
        guard let url = Bundle.module.url(forResource: "whisperkit-model-manifest", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(contentsOf: url)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
