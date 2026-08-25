// ModelStorageScanner — the pure filesystem-inspection logic behind the Settings "Storage"
// section. Exercised entirely against temp directories mimicking WhisperKit's and
// SortformerModelStore's real on-disk layouts; no network, no real Application Support paths.

import Foundation
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

    /// Mimics `WhisperKit.download`'s real layout: `<base>/models/argmaxinc/whisperkit-coreml/<variant>/...`.
    private func whisperVariantDir(in base: URL, variant: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    // MARK: - WhisperKit scanning

    @Test func findsAKnownVariantAndSumsItsFiles() throws {
        try withTempDir { base in
            let dir = whisperVariantDir(in: base, variant: "openai_whisper-base")
            try write(1_000, to: dir.appendingPathComponent("AudioEncoder.mlmodelc/weights.bin"))
            try write(2_000, to: dir.appendingPathComponent("TextDecoder.mlmodelc/weights.bin"))

            let models = ModelStorageScanner.scanWhisperKitModels(downloadBase: base)
            #expect(models.count == 1)
            #expect(models[0].kind == .whisper(.base))
            #expect(models[0].bytes == 3_000)
            // Directory enumeration resolves symlinks in the returned URL (e.g. /tmp →
            // /private/tmp), so compare the meaningful suffix rather than exact URL equality.
            #expect(models[0].paths.count == 1)
            #expect(models[0].paths[0].path.hasSuffix(dir.path))
        }
    }

    @Test func ignoresADirectoryThatDoesNotMatchAnyKnownVariant() throws {
        try withTempDir { base in
            let dir = whisperVariantDir(in: base, variant: "some_unrelated_model")
            try write(500, to: dir.appendingPathComponent("file.bin"))

            let models = ModelStorageScanner.scanWhisperKitModels(downloadBase: base)
            #expect(models.isEmpty)
        }
    }

    @Test func ignoresTheHiddenCacheDirectory() throws {
        try withTempDir { base in
            let repoDir = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            try write(999, to: repoDir.appendingPathComponent(".cache/huggingface/some-metadata"))

            let models = ModelStorageScanner.scanWhisperKitModels(downloadBase: base)
            #expect(models.isEmpty)
        }
    }

    @Test func ignoresAnEmptyVariantDirectory() throws {
        try withTempDir { base in
            let dir = whisperVariantDir(in: base, variant: "openai_whisper-tiny")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let models = ModelStorageScanner.scanWhisperKitModels(downloadBase: base)
            #expect(models.isEmpty)
        }
    }

    @Test func findsMultipleVariantsSortedLargestFirstViaScan() throws {
        try withTempDir { base in
            try write(1_000, to: whisperVariantDir(in: base, variant: "openai_whisper-tiny").appendingPathComponent("a.bin"))
            try write(5_000, to: whisperVariantDir(in: base, variant: "openai_whisper-base").appendingPathComponent("a.bin"))

            let models = ModelStorageScanner.scan(whisperKitDownloadBase: base,
                                                  sortformerRoot: base.appendingPathComponent("no-sortformer-here"),
                                                  speechSynthesisRoot: base.appendingPathComponent("no-ttskit-here"))
            #expect(models.map(\.kind) == [.whisper(.base), .whisper(.tiny)])
        }
    }

    @Test func missingDownloadBaseReturnsNoModels() throws {
        try withTempDir { base in
            let models = ModelStorageScanner.scanWhisperKitModels(downloadBase: base.appendingPathComponent("never-created"))
            #expect(models.isEmpty)
        }
    }

    // MARK: - Sortformer diarizer scanning

    @Test func findsTheDiarizerModelWhenArtifactsArePresent() throws {
        try withTempDir { root in
            let store = SortformerModelStore(root: root)
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(SortformerModelStore.melFilterBytes, to: store.melFiltersURL)
            try write(4, to: store.metadataURL)

            let models = ModelStorageScanner.scanSortformerModel(root: root)
            #expect(models.count == 1)
            #expect(models[0].kind == .diarizer)
            #expect(models[0].bytes == Int64(SortformerModelStore.mainMlirbBytes + SortformerModelStore.melFilterBytes))
            // Owns only its own artifacts, never metadata.json/the manifest at the shared root.
            #expect(Set(models[0].paths) == Set([store.modelURL, store.melFiltersURL]))
        }
    }

    @Test func findsNoDiarizerModelWhenArtifactsAreMissing() throws {
        try withTempDir { root in
            let models = ModelStorageScanner.scanSortformerModel(root: root)
            #expect(models.isEmpty)
        }
    }

    // MARK: - Speech synthesis (TTSKit) scanning

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

    @Test func scanListsSynthesisBesideTheAsrModelsSortedBySize() throws {
        try withTempDir { base in
            try write(5_000, to: whisperVariantDir(in: base, variant: "openai_whisper-base").appendingPathComponent("a.bin"))
            let ttsRoot = base.appendingPathComponent("ttskit", isDirectory: true)
            try write(9_000, to: ttsRoot.appendingPathComponent("models/argmaxinc/ttskit-coreml/weights.bin"))

            let models = ModelStorageScanner.scan(whisperKitDownloadBase: base,
                                                  sortformerRoot: base.appendingPathComponent("no-sortformer-here"),
                                                  speechSynthesisRoot: ttsRoot)
            #expect(models.map(\.kind) == [.speechSynthesis, .whisper(.base)])
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
        try withTempDir { base in
            let dir = whisperVariantDir(in: base, variant: "openai_whisper-base")
            try write(100, to: dir.appendingPathComponent("a.bin"))
            let sibling = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-tiny", isDirectory: true)
            try write(50, to: sibling.appendingPathComponent("a.bin"))

            let model = StoredModel(kind: .whisper(.base), paths: [dir], bytes: 100)
            try ModelStorageScanner.delete(model)

            #expect(!FileManager.default.fileExists(atPath: dir.path))
            #expect(FileManager.default.fileExists(atPath: sibling.path))   // untouched
        }
    }

    @Test func deleteThrowsWhenAPathIsAlreadyMissingButStillRemovesTheRest() throws {
        try withTempDir { base in
            let present = base.appendingPathComponent("present.bin")
            try write(10, to: present)
            let missing = base.appendingPathComponent("already-gone.bin")

            let model = StoredModel(kind: .diarizer, paths: [missing, present], bytes: 10)
            #expect(throws: Error.self) { try ModelStorageScanner.delete(model) }
            #expect(!FileManager.default.fileExists(atPath: present.path))   // still removed
        }
    }

    @Test func rescanAfterDeleteNoLongerFindsTheModel() throws {
        try withTempDir { base in
            let dir = whisperVariantDir(in: base, variant: "openai_whisper-small")
            try write(200, to: dir.appendingPathComponent("a.bin"))
            #expect(ModelStorageScanner.scanWhisperKitModels(downloadBase: base).count == 1)

            try ModelStorageScanner.delete(StoredModel(kind: .whisper(.small), paths: [dir], bytes: 200))

            #expect(ModelStorageScanner.scanWhisperKitModels(downloadBase: base).isEmpty)
        }
    }

    // MARK: - StoredModel display

    @Test func displayNamesMatchTheSettingsPickerForWhisperAndAreDistinctForTheDiarizer() {
        let whisper = StoredModel(kind: .whisper(.largeTurbo), paths: [], bytes: 0)
        #expect(whisper.displayName == AppSettings.WhisperModel.largeTurbo.displayName)

        let diarizer = StoredModel(kind: .diarizer, paths: [], bytes: 0)
        #expect(diarizer.displayName == "Streaming Sortformer")
        #expect(diarizer.id != whisper.id)
    }
}
