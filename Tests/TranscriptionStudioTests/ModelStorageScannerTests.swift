// ModelStorageScanner — the pure filesystem-inspection logic behind the Settings "Storage"
// section. Exercised entirely against temp directories mimicking the speech models' and the
// synthesis engine's real on-disk layouts; no network, no real Application Support paths.

import Foundation
import Synchronization
import Testing
@testable import TranscriptionStudio

@Suite("ModelStorageScanner — on-disk model inventory")
struct ModelStorageScannerTests {

    /// A fresh temp root per test, removed at the end regardless of outcome.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        // /tmp is itself a symlink to /private/tmp, and the scanner's FileManager enumeration
        // returns fully-resolved paths, so an unresolved root would never `==` what comes back
        // out of a scan. `resolvingSymlinksInPath()` only resolves what already exists on disk,
        // so the directory has to be created first.
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        let root = unresolved.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: unresolved) }
        try body(root)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try Data(repeating: 0x1, count: bytes).write(to: url)
    }

    // MARK: - Speech models

    @Test func findsEachSpeechModelByItsDirectoryAndSumsItsFiles() throws {
        try withTempDir { root in
            try write(1_000, to: SpeechModel.parakeet.directory(under: root).appendingPathComponent("ParakeetEncoder.mlmodelc/weights/weight.bin"))
            try write(24, to: SpeechModel.parakeet.directory(under: root).appendingPathComponent("ParakeetEncoder.mlmodelc/model.mil"))
            try write(300, to: SpeechModel.sortformer.directory(under: root).appendingPathComponent("Sortformer.mlmodelc/weights/weight.bin"))

            let models = ModelStorageScanner.scanSpeechModels(root: root)
            #expect(models.map(\.kind) == [.speech(.parakeet), .speech(.sortformer)])
            #expect(models[0].bytes == 1_024)
            #expect(models[0].paths == [SpeechModel.parakeet.directory(under: root)])
            #expect(models[1].bytes == 300)
        }
    }

    @Test func ignoresADirectoryThatIsNotASpeechModelAndAnEmptyOne() throws {
        try withTempDir { root in
            try write(500, to: root.appendingPathComponent("whisperkit/weights.bin"))
            try FileManager.default.createDirectory(at: SpeechModel.senseVoice.directory(under: root),
                                                     withIntermediateDirectories: true)
            #expect(ModelStorageScanner.scanSpeechModels(root: root).isEmpty)
        }
    }

    @Test func missingRootReturnsNoModels() throws {
        try withTempDir { base in
            #expect(ModelStorageScanner.scanSpeechModels(root: base.appendingPathComponent("never-created")).isEmpty)
        }
    }

    // MARK: - Speech synthesis (TTSKit)

    /// Mimics the engine's real layout: weights + tokenizer + Hub bookkeeping all under one
    /// `ttskit` root that exists solely for synthesis.
    @Test func findsTheSynthesisModelAndSumsTheWholeRoot() throws {
        try withTempDir { base in
            let root = base.appendingPathComponent("ttskit", isDirectory: true)
            try write(3_000, to: root.appendingPathComponent("models/argmaxinc/ttskit-coreml/qwen3_tts/code_decoder.mlmodelc/weights.bin"))
            try write(1_000, to: root.appendingPathComponent("models/Qwen/Qwen3-0.6B/tokenizer.json"))
            try write(200, to: root.appendingPathComponent("models/argmaxinc/ttskit-coreml/.cache/huggingface/metadata"))

            let models = ModelStorageScanner.scanSpeechSynthesisModel(root: root)
            #expect(models.count == 1)
            #expect(models[0].kind == .speechSynthesis)
            // The whole root is the footprint — weights, tokenizer, AND the Hub bookkeeping.
            #expect(models[0].bytes == 4_200)
            #expect(models[0].paths == [root])
        }
    }

    @Test func findsNoSynthesisModelWhenTheRootIsMissingOrEmpty() throws {
        try withTempDir { base in
            #expect(ModelStorageScanner.scanSpeechSynthesisModel(root: base.appendingPathComponent("never-created")).isEmpty)

            let empty = base.appendingPathComponent("ttskit", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            #expect(ModelStorageScanner.scanSpeechSynthesisModel(root: empty).isEmpty)
        }
    }

    @Test func scanListsEverythingSortedLargestFirst() throws {
        try withTempDir { base in
            let speech = base.appendingPathComponent("fctspeech", isDirectory: true)
            try write(5_000, to: SpeechModel.senseVoice.directory(under: speech).appendingPathComponent("SenseVoice.mlmodelc/weights/weight.bin"))
            try write(7_000, to: SpeechModel.parakeet.directory(under: speech).appendingPathComponent("ParakeetEncoder.mlmodelc/weights/weight.bin"))
            let ttsRoot = base.appendingPathComponent("ttskit", isDirectory: true)
            try write(9_000, to: ttsRoot.appendingPathComponent("models/argmaxinc/ttskit-coreml/weights.bin"))

            let models = ModelStorageScanner.scan(speechRoot: speech, speechSynthesisRoot: ttsRoot)
            #expect(models.map(\.kind) == [.speechSynthesis, .speech(.parakeet), .speech(.senseVoice)])
        }
    }

    @Test func rescanAfterDeletingTheSynthesisModelNoLongerFindsIt() throws {
        try withTempDir { base in
            let root = base.appendingPathComponent("ttskit", isDirectory: true)
            try write(500, to: root.appendingPathComponent("models/argmaxinc/ttskit-coreml/weights.bin"))
            let found = ModelStorageScanner.scanSpeechSynthesisModel(root: root)
            #expect(found.count == 1)

            try ModelStorageScanner.delete(found[0])

            #expect(!FileManager.default.fileExists(atPath: root.path))
            #expect(ModelStorageScanner.scanSpeechSynthesisModel(root: root).isEmpty)
        }
    }

    // MARK: - delete

    @Test func deleteRemovesOnlyTheOwnedPaths() throws {
        try withTempDir { root in
            let parakeet = SpeechModel.parakeet.directory(under: root)
            try write(100, to: parakeet.appendingPathComponent("a.bin"))
            let sibling = SpeechModel.sortformer.directory(under: root)
            try write(50, to: sibling.appendingPathComponent("a.bin"))

            try ModelStorageScanner.delete(StoredModel(kind: .speech(.parakeet), paths: [parakeet], bytes: 100))

            #expect(!FileManager.default.fileExists(atPath: parakeet.path))
            #expect(FileManager.default.fileExists(atPath: sibling.path))   // untouched
        }
    }

    @Test func deleteThrowsWhenAPathIsAlreadyMissingButStillRemovesTheRest() throws {
        try withTempDir { base in
            let present = base.appendingPathComponent("present.bin")
            try write(10, to: present)
            let missing = base.appendingPathComponent("already-gone.bin")

            let model = StoredModel(kind: .speech(.sortformer), paths: [missing, present], bytes: 10)
            #expect(throws: Error.self) { try ModelStorageScanner.delete(model) }
            #expect(!FileManager.default.fileExists(atPath: present.path))   // still removed
        }
    }

    @Test func rescanAfterDeleteNoLongerFindsTheModel() throws {
        try withTempDir { root in
            let dir = SpeechModel.senseVoice.directory(under: root)
            try write(200, to: dir.appendingPathComponent("a.bin"))
            #expect(ModelStorageScanner.scanSpeechModels(root: root).count == 1)

            try ModelStorageScanner.delete(StoredModel(kind: .speech(.senseVoice), paths: [dir], bytes: 200))

            #expect(ModelStorageScanner.scanSpeechModels(root: root).isEmpty)
        }
    }

    // MARK: - StoredModel display

    @Test func displayNamesAndDetailsAreTheModelsOwnAndDistinct() {
        let rows = SpeechModel.allCases.map { StoredModel(kind: .speech($0), paths: [], bytes: 0) }
            + [StoredModel(kind: .speechSynthesis, paths: [], bytes: 0)]
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(Set(rows.map(\.displayName)).count == rows.count)
        for (row, model) in zip(rows, SpeechModel.allCases) {
            #expect(row.displayName == model.displayName)
            #expect(row.detail == model.detail)
        }
        #expect(rows.last?.detail == "Speech synthesis")
    }
}

@Suite("SpeechModelStore — manifest, layout, staging and install")
struct SpeechModelStoreTests {

    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unresolved) }
        try body(unresolved.resolvingSymlinksInPath())
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2, count: bytes).write(to: url)
    }

    private let manifest = ModelManifest(repo: "fcttechnologies/fctspeech-coreml", assets: [
        ModelAsset(path: "parakeet-v3/ParakeetEncoder.mlmodelc/weights/weight.bin", size: 100),
        ModelAsset(path: "parakeet-v3/ParakeetEncoder.mlmodelc/model.mil", size: 10),
        ModelAsset(path: "sortformer/Sortformer.mlmodelc/weights/weight.bin", size: 50),
    ])

    @Test func anAssetNamesItsModelByItsFirstPathComponent() {
        #expect(ModelAsset(path: "sensevoice/SenseVoice.mlmodelc/model.mil", size: 1).model == .senseVoice)
        #expect(ModelAsset(path: "whisper/x", size: 1).model == nil)
        #expect(manifest.assets(of: .parakeet).count == 2)
        #expect(manifest.assets(of: .senseVoice).isEmpty)
        #expect(manifest.totalSize == 160)
    }

    @Test func theShippedManifestListsEveryModelWithPositiveSizesAndMatchesTheHostedJSON() throws {
        let bundled = ModelManifest.shipped
        // The hosted JSON and the compiled-in copy come from one script run; pinned equal here so
        // a regenerate that updated one and not the other cannot ship.
        let json = try #require(Bundle.main.url(forResource: "speech-model-manifest", withExtension: "json"))
        #expect(try ModelManifest.load(contentsOf: json) == bundled)
        for model in SpeechModel.allCases {
            let assets = bundled.assets(of: model)
            #expect(!assets.isEmpty, "\(model.rawValue) has no files in the manifest")
            #expect(assets.allSatisfy { $0.size > 0 })
        }
        #expect(bundled.assets.allSatisfy { $0.model != nil })
    }

    @Test func downloadURLResolvesFromTheRepoOnHuggingFace() {
        let url = ModelLayout.downloadURL(repo: "fcttechnologies/fctspeech-coreml", path: "sortformer/Sortformer.mlmodelc/model.mil")
        #expect(url?.absoluteString == "https://huggingface.co/fcttechnologies/fctspeech-coreml/resolve/main/sortformer/Sortformer.mlmodelc/model.mil")
    }

    @Test func manifestRoundTripsThroughItsOwnEncoding() throws {
        let data = try manifest.encoded()
        #expect(try ModelManifest.decode(from: data) == manifest)
    }

    @Test func pendingAssetsSkipsFilesPresentAtExactSizeInstalledOrStaged() throws {
        try withTempDir { base in
            let root = base.appendingPathComponent("root", isDirectory: true)
            let group = base.appendingPathComponent("group", isDirectory: true)
            try write(100, to: ModelLayout.installedURL(root: root, path: manifest.assets[0].path))   // installed
            try write(9, to: ModelLayout.installedURL(root: root, path: manifest.assets[1].path))     // wrong size
            try write(50, to: ModelLayout.stagedURL(appGroupContainer: group, path: manifest.assets[2].path)) // staged

            let pending = ModelLayout.pendingAssets(manifest.assets, root: root, appGroupContainer: group,
                                                    sizeAt: SpeechModelStore.fileSize)
            #expect(pending == [manifest.assets[1]])
            // Without a staging area the staged file does not count.
            let withoutGroup = ModelLayout.pendingAssets(manifest.assets, root: root, appGroupContainer: nil,
                                                         sizeAt: SpeechModelStore.fileSize)
            #expect(withoutGroup == [manifest.assets[1], manifest.assets[2]])
        }
    }

    @Test func installStagedModelsMovesEveryStagedFileIntoTheRootAndLeavesInstalledOnes() throws {
        try withTempDir { base in
            let root = base.appendingPathComponent("root", isDirectory: true)
            let group = base.appendingPathComponent("group", isDirectory: true)
            for asset in manifest.assets {
                try write(asset.size, to: ModelLayout.stagedURL(appGroupContainer: group, path: asset.path))
            }
            // One is already installed at the same size: it is dropped from staging, not moved.
            try write(50, to: ModelLayout.installedURL(root: root, path: manifest.assets[2].path))

            #expect(SpeechModelStore.installStagedModels(appGroupContainer: group, root: root) == 2)
            for asset in manifest.assets {
                #expect(SpeechModelStore.fileSize(ModelLayout.installedURL(root: root, path: asset.path)) == asset.size)
                #expect(!FileManager.default.fileExists(atPath: ModelLayout.stagedURL(appGroupContainer: group, path: asset.path).path))
            }
            #expect(SpeechModelStore.installStagedModels(appGroupContainer: group, root: root) == 0)
            #expect(SpeechModelStore.installStagedModels(appGroupContainer: nil, root: root) == 0)
        }
    }

    @Test func isInstalledDemandsEveryFileAtItsExactSize() throws {
        try withTempDir { root in
            #expect(!SpeechModelStore.isInstalled(.parakeet, manifest: manifest, root: root))
            try write(100, to: ModelLayout.installedURL(root: root, path: manifest.assets[0].path))
            #expect(!SpeechModelStore.isInstalled(.parakeet, manifest: manifest, root: root))
            try write(10, to: ModelLayout.installedURL(root: root, path: manifest.assets[1].path))
            #expect(SpeechModelStore.isInstalled(.parakeet, manifest: manifest, root: root))
            #expect(!SpeechModelStore.isInstalled(.senseVoice, manifest: manifest, root: root))
            #expect(!SpeechModelStore.isInstalled(.parakeet, manifest: nil, root: root))
        }
    }

    @Test func ensureInstalledReturnsWithoutTheNetworkWhenEverythingIsPresent() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        for asset in manifest.assets(of: .sortformer) {
            try write(asset.size, to: ModelLayout.installedURL(root: root, path: asset.path))
        }
        // A session whose every request fails: a download attempt would surface as an error.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingURLProtocol.self]
        let session = URLSession(configuration: config)
        let fractions = Mutex<[Double]>([])
        try await SpeechModelStore.ensureInstalled(.sortformer, manifest: manifest, root: root,
                                                   appGroupContainer: nil, session: session) { f in fractions.withLock { $0.append(f) } }
        #expect(fractions.withLock { $0 } == [1.0])
    }

    @Test func ensureInstalledRefusesAModelTheManifestDoesNotList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: SpeechModelStoreError.notInManifest(.senseVoice)) {
            try await SpeechModelStore.ensureInstalled(.senseVoice, manifest: manifest, root: root, appGroupContainer: nil) { _ in }
        }
        await #expect(throws: SpeechModelStoreError.noManifest) {
            try await SpeechModelStore.ensureInstalled(.parakeet, manifest: nil, root: root, appGroupContainer: nil) { _ in }
        }
    }

    @Test func ensureInstalledDownloadsOnlyWhatIsMissingAndVerifiesTheSize() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        try write(100, to: ModelLayout.installedURL(root: root, path: manifest.assets[0].path))   // present

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServingURLProtocol.self]
        ServingURLProtocol.bodies.withLock { $0 = [
            "/fcttechnologies/fctspeech-coreml/resolve/main/parakeet-v3/ParakeetEncoder.mlmodelc/model.mil": Data(repeating: 0x3, count: 10),
        ] }
        let session = URLSession(configuration: config)
        let fractions = Mutex<[Double]>([])
        try await SpeechModelStore.ensureInstalled(.parakeet, manifest: manifest, root: root,
                                                   appGroupContainer: nil, session: session) { f in fractions.withLock { $0.append(f) } }
        #expect(SpeechModelStore.isInstalled(.parakeet, manifest: manifest, root: root))
        #expect(ServingURLProtocol.requested.withLock { $0 } == ["/fcttechnologies/fctspeech-coreml/resolve/main/parakeet-v3/ParakeetEncoder.mlmodelc/model.mil"])
        #expect(fractions.withLock { $0 } == [100.0 / 110.0, 1.0])

        // A server that delivers the wrong number of bytes is refused, and nothing lands.
        ServingURLProtocol.bodies.withLock { $0 = [
            "/fcttechnologies/fctspeech-coreml/resolve/main/sortformer/Sortformer.mlmodelc/weights/weight.bin": Data(repeating: 0x3, count: 49),
        ] }
        await #expect(throws: SpeechModelStoreError.sizeMismatch(manifest.assets[2].path, expected: 50, got: 49)) {
            try await SpeechModelStore.ensureInstalled(.sortformer, manifest: manifest, root: root,
                                                       appGroupContainer: nil, session: session) { _ in }
        }
        #expect(!SpeechModelStore.isInstalled(.sortformer, manifest: manifest, root: root))
    }
}

/// A URL protocol that refuses every request: proof that a code path never touched the network.
final class RefusingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// A URL protocol serving fixed bodies by path and recording what was asked for.
final class ServingURLProtocol: URLProtocol {
    static let bodies = Mutex<[String: Data]>([:])
    static let requested = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requested.withLock { $0.append(path) }
        guard let body = Self.bodies.withLock({ $0[path] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
