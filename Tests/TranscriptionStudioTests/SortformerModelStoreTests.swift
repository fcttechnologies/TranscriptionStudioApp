// SortformerModelStore's integrity/path logic, exercised purely on the local filesystem (no
// network): manifest resolution (local override vs the HF-original default), size/hash
// verification, and the derived artifact paths. The network-dependent `download`/`provision`
// paths aren't covered here — they need a real or mocked URLSession and are exercised by the
// scripted fetch path instead.

import CryptoKit
import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("SortformerModelStore — integrity")
struct SortformerModelStoreTests {

    /// A fresh temp root per test, removed at the end regardless of outcome — the big-file
    /// size checks create sparse files (real disk footprint stays tiny), but cleanup still
    /// keeps /tmp from accumulating one directory per test run.
    private func withTempStore(_ body: (SortformerModelStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SortformerModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SortformerModelStore(root: root))
    }

    /// A sparse file of exactly `bytes` length — cheap regardless of size since only the
    /// reported size (not content) matters for these checks.
    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    // MARK: - Paths

    @Test func derivedURLsNestUnderTheGivenRoot() throws {
        try withTempStore { store in
            let root = store.root
            #expect(store.modelURL == root.appendingPathComponent("sortformer_float16.aimodel", isDirectory: true))
            #expect(store.mainMlirbURL == store.modelURL.appendingPathComponent("main.mlirb"))
            #expect(store.melFiltersURL == root.appendingPathComponent("sortformer_mel_filters_128x257.f32"))
            #expect(store.metadataURL == root.appendingPathComponent("metadata.json"))
            #expect(store.manifestURL == root.appendingPathComponent(SortformerManifest.filename))
        }
    }

    // MARK: - hasLocalArtifacts / artifactsPresent

    @Test func hasLocalArtifactsIsFalseWhenNothingIsProvisioned() throws {
        try withTempStore { store in
            #expect(!store.hasLocalArtifacts)
            #expect(!store.artifactsPresent)
        }
    }

    @Test func hasLocalArtifactsIsFalseWhenAFileIsPresentButEmpty() throws {
        try withTempStore { store in
            try write(0, to: store.mainMlirbURL)
            try write(SortformerModelStore.melFilterBytes, to: store.melFiltersURL)
            try write(4, to: store.metadataURL)
            #expect(!store.hasLocalArtifacts)   // main.mlirb is empty
        }
    }

    @Test func hasLocalArtifactsIsTrueWhenAllThreeArtifactsAreNonEmpty() throws {
        try withTempStore { store in
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(SortformerModelStore.melFilterBytes, to: store.melFiltersURL)
            try write(4, to: store.metadataURL)
            #expect(store.hasLocalArtifacts)
        }
    }

    // MARK: - verifyArtifacts (default HF manifest)

    @Test func verifyArtifactsThrowsMissingArtifactWhenNothingExists() throws {
        try withTempStore { store in
            #expect(throws: SortformerModelError.self) { try store.verifyArtifacts() }
        }
    }

    @Test func verifyArtifactsThrowsSizeMismatchForAPartialFile() throws {
        try withTempStore { store in
            // Right size mel filter but a short (partial-download-like) main.mlirb.
            try write(SortformerModelStore.melFilterBytes, to: store.melFiltersURL)
            try write(1_000, to: store.mainMlirbURL)
            try write(4, to: store.metadataURL)

            do {
                try store.verifyArtifacts()
                Issue.record("expected verifyArtifacts to throw")
            } catch SortformerModelError.sizeMismatch(let file, let expected, let got) {
                #expect(file.hasSuffix("main.mlirb"))
                #expect(expected == SortformerModelStore.mainMlirbBytes)
                #expect(got == 1_000)
            } catch {
                Issue.record("expected .sizeMismatch, got \(error)")
            }
        }
    }

    @Test func verifyArtifactsThrowsMissingMetadataEvenWhenBigFilesAreCorrectSize() throws {
        try withTempStore { store in
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(SortformerModelStore.melFilterBytes, to: store.melFiltersURL)
            // metadata.json deliberately absent.

            do {
                try store.verifyArtifacts()
                Issue.record("expected verifyArtifacts to throw")
            } catch SortformerModelError.missingArtifact(let name) {
                #expect(name == "metadata.json")
            } catch {
                Issue.record("expected .missingArtifact, got \(error)")
            }
        }
    }

    @Test func verifyArtifactsSucceedsWhenEverythingMatchesTheDefaultManifest() throws {
        try withTempStore { store in
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(SortformerModelStore.melFilterBytes, to: store.melFiltersURL)
            try write(4, to: store.metadataURL)

            #expect(throws: Never.self) { try store.verifyArtifacts() }
            #expect(store.artifactsPresent)
        }
    }

    // MARK: - effectiveManifest (local override)

    @Test func effectiveManifestFallsBackToHFDefaultWithNoLocalManifest() throws {
        try withTempStore { store in
            let manifest = store.effectiveManifest()
            #expect(manifest.files.count == SortformerManifest.hfDefault.files.count)
            #expect(manifest.files.map(\.bytes) == SortformerManifest.hfDefault.files.map(\.bytes))
        }
    }

    @Test func writeManifestPersistsACustomManifestThatOverridesTheDefault() throws {
        try withTempStore { store in
            // A re-exported model's manifest: different (smaller) sizes than the HF original.
            let custom = SortformerManifest(files: [
                .init(name: "sortformer_mel_filters_128x257.f32", bytes: 131_584),
                .init(name: "sortformer_float16.aimodel/main.mlirb", bytes: 12_345),
            ])
            try store.writeManifest(custom)

            let effective = store.effectiveManifest()
            #expect(effective.files.first { $0.name.hasSuffix("main.mlirb") }?.bytes == 12_345)

            // verifyArtifacts now checks against the CUSTOM sizes, not the HF default —
            // a file sized to the HF original would fail; sized to the custom manifest, it passes.
            try write(131_584, to: store.melFiltersURL)
            try write(12_345, to: store.mainMlirbURL)
            try write(4, to: store.metadataURL)
            #expect(throws: Never.self) { try store.verifyArtifacts() }
        }
    }

    @Test func localManifestRejectsAFileSizedToTheHFDefaultInstead() throws {
        try withTempStore { store in
            let custom = SortformerManifest(files: [
                .init(name: "sortformer_mel_filters_128x257.f32", bytes: 131_584),
                .init(name: "sortformer_float16.aimodel/main.mlirb", bytes: 12_345),
            ])
            try store.writeManifest(custom)

            // Sized to the HF-original default, NOT the local manifest's expectation — must fail.
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(131_584, to: store.melFiltersURL)
            try write(4, to: store.metadataURL)

            #expect(throws: SortformerModelError.self) { try store.verifyArtifacts() }
        }
    }

    // MARK: - SHA-256 verification

    @Test func hashMismatchIsDetectedWhenTheManifestPinsASHA() throws {
        try withTempStore { store in
            let melBytes = Data(repeating: 0x11, count: 131_584)
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try melBytes.write(to: store.melFiltersURL)

            let wrongHash = SHA256.hash(data: Data(repeating: 0x99, count: 4))
                .map { String(format: "%02x", $0) }.joined()
            let manifest = SortformerManifest(files: [
                .init(name: "sortformer_mel_filters_128x257.f32", bytes: 131_584, sha256: wrongHash),
            ])
            try store.writeManifest(manifest)
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(4, to: store.metadataURL)

            do {
                try store.verifyArtifacts()
                Issue.record("expected a hash mismatch")
            } catch SortformerModelError.hashMismatch(let file) {
                #expect(file.hasSuffix("mel_filters_128x257.f32"))
            } catch {
                Issue.record("expected .hashMismatch, got \(error)")
            }
        }
    }

    @Test func correctSHAPassesVerification() throws {
        try withTempStore { store in
            let melBytes = Data(repeating: 0x11, count: 131_584)
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try melBytes.write(to: store.melFiltersURL)

            let correctHash = SHA256.hash(data: melBytes).map { String(format: "%02x", $0) }.joined()
            let manifest = SortformerManifest(files: [
                .init(name: "sortformer_mel_filters_128x257.f32", bytes: 131_584, sha256: correctHash),
            ])
            try store.writeManifest(manifest)
            try write(SortformerModelStore.mainMlirbBytes, to: store.mainMlirbURL)
            try write(4, to: store.metadataURL)

            #expect(throws: Never.self) { try store.verifyArtifacts() }
        }
    }

    // MARK: - loadMelFilters

    @Test func loadMelFiltersReturnsTheRawFloatsWhenSizeMatches() throws {
        try withTempStore { store in
            let count = 128 * 257
            var floats = [Float](repeating: 0, count: count)
            for i in 0..<count { floats[i] = Float(i) * 0.001 }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            try data.write(to: store.melFiltersURL)

            let loaded = try store.loadMelFilters()
            #expect(loaded.count == count)
            #expect(loaded[1] == floats[1])
            #expect(loaded[count - 1] == floats[count - 1])
        }
    }

    @Test func loadMelFiltersThrowsOnAWrongSizedFile() throws {
        try withTempStore { store in
            try write(100, to: store.melFiltersURL)
            #expect(throws: SortformerModelError.self) { try store.loadMelFilters() }
        }
    }
}
