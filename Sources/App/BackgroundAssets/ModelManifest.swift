import Foundation

/// One file of a speech model: its path relative to the models root (`<model>/<relpath>`, so
/// the first component names the `SpeechModel`) and its exact byte size. Background Assets
/// requires the size to match the file the server delivers — a mismatch fails the download — so
/// these come from the real on-disk model, never an estimate.
struct ModelAsset: Codable, Sendable, Equatable, Hashable {
    let path: String
    let size: Int

    init(path: String, size: Int) {
        self.path = path
        self.size = size
    }

    /// The model this file belongs to, from the path's first component.
    var model: SpeechModel? {
        path.split(separator: "/", maxSplits: 1).first.flatMap { SpeechModel(rawValue: String($0)) }
    }
}

/// The self-hosted Background Assets manifest for the app's speech models. The system downloads
/// this file (via the app's `BAManifestURL` Info.plist key) before it wakes the downloader
/// extension, then hands the extension the on-disk location; the extension parses it to learn
/// which files to schedule, their download URLs, and their sizes. The app and the CLI read the
/// compiled-in copy for the completeness check and the download.
///
/// The schema is the app's to define: the hosted repo the files resolve from, and every file of
/// every model with its exact size.
struct ModelManifest: Codable, Sendable, Equatable {
    /// The HuggingFace repo the files resolve from, `<owner>/<name>`.
    let repo: String
    /// Every file of every model, `<model>/<relpath>`, with exact byte sizes.
    let assets: [ModelAsset]

    init(repo: String, assets: [ModelAsset]) {
        self.repo = repo
        self.assets = assets
    }

    /// The files of one model.
    func assets(of model: SpeechModel) -> [ModelAsset] {
        assets.filter { $0.model == model }
    }

    /// Total download size across all assets — the value the app declares in `BAMaxInstallSize`.
    var totalSize: Int { assets.reduce(0) { $0 + $1.size } }

    static func decode(from data: Data) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    static func load(contentsOf url: URL) throws -> ModelManifest {
        try decode(from: Data(contentsOf: url))
    }

    /// The manifest compiled into every target (`ShippedModelManifest.swift`, generated beside
    /// the hosted JSON from the same enumeration). The extension itself parses the
    /// system-downloaded copy at its `manifestURL`, so a server update takes effect there
    /// without an app update.
    static func bundled() -> ModelManifest { shipped }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
