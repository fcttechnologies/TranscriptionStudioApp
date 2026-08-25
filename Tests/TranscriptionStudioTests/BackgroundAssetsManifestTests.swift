// BackgroundAssetsKit — the pure manifest + path/URL math behind the Background Assets model
// pre-download. No network, no App Group, no real Application Support: every layout method takes
// its roots explicitly, so these run against literal URLs and temp directories.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("Background Assets — manifest + layout math")
struct BackgroundAssetsManifestTests {

    private let repo = "argmaxinc/whisperkit-coreml"
    private let variant = "openai_whisper-large-v3-v20240930_turbo"

    // MARK: - HuggingFace URL construction

    @Test("HuggingFace resolve URL is built from repo + variant + relative path")
    func downloadURLFromRelativePath() {
        let url = WhisperKitModelLayout.downloadURL(
            repo: repo, variant: variant,
            relativePath: "AudioEncoder.mlmodelc/weights/weight.bin")
        #expect(url?.absoluteString ==
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/weights/weight.bin")
    }

    @Test("A top-level file maps to a resolve URL without an extra path segment")
    func downloadURLTopLevelFile() {
        let url = WhisperKitModelLayout.downloadURL(repo: repo, variant: variant, relativePath: "config.json")
        #expect(url?.absoluteString ==
            "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-large-v3-v20240930_turbo/config.json")
        #expect(url?.scheme == "https")
        #expect(url?.host == "huggingface.co")
    }

    // MARK: - Install / staging path mapping

    @Test("Install relative path mirrors WhisperKit's download-base layout")
    func installRelativePathLayout() {
        let path = WhisperKitModelLayout.installRelativePath(
            repo: repo, variant: variant, relativePath: "TextDecoder.mlmodelc/weights/weight.bin")
        #expect(path == "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/weights/weight.bin")
    }

    @Test("Staged and installed URLs append the install path to their roots")
    func stagedAndInstalledURLs() {
        let group = URL(fileURLWithPath: "/group", isDirectory: true)
        let base = URL(fileURLWithPath: "/base", isDirectory: true)
        let installPath = WhisperKitModelLayout.installRelativePath(
            repo: repo, variant: variant, relativePath: "config.json")

        let staged = WhisperKitModelLayout.stagedURL(appGroupContainer: group, installRelativePath: installPath)
        #expect(staged.path ==
            "/group/BackgroundAssets/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo/config.json")

        let installed = WhisperKitModelLayout.installedURL(downloadBase: base, installRelativePath: installPath)
        #expect(installed.path ==
            "/base/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo/config.json")
    }

    // MARK: - Pending-asset planner

    @Test("Only assets missing (or wrong-sized) at both locations are pending")
    func pendingAssetsPlanner() {
        let manifest = WhisperKitModelManifest(repo: repo, variant: variant, assets: [
            WhisperKitModelAsset(path: "a.bin", size: 10),   // installed correctly → not pending
            WhisperKitModelAsset(path: "b.bin", size: 20),   // staged correctly → not pending
            WhisperKitModelAsset(path: "c.bin", size: 30),   // installed but wrong size → pending
            WhisperKitModelAsset(path: "d.bin", size: 40),   // absent everywhere → pending
        ])
        let base = URL(fileURLWithPath: "/base", isDirectory: true)
        let group = URL(fileURLWithPath: "/group", isDirectory: true)

        // Model each file's on-disk size by URL.
        func rel(_ p: String) -> String {
            WhisperKitModelLayout.installRelativePath(repo: repo, variant: variant, relativePath: p)
        }
        let sizes: [String: Int] = [
            WhisperKitModelLayout.installedURL(downloadBase: base, installRelativePath: rel("a.bin")).path: 10,
            WhisperKitModelLayout.stagedURL(appGroupContainer: group, installRelativePath: rel("b.bin")).path: 20,
            WhisperKitModelLayout.installedURL(downloadBase: base, installRelativePath: rel("c.bin")).path: 999,
        ]

        let pending = WhisperKitModelLayout.pendingAssets(
            manifest: manifest, downloadBase: base, appGroupContainer: group,
            sizeAt: { sizes[$0.path] })

        #expect(pending.map(\.path) == ["c.bin", "d.bin"])
    }

    // MARK: - Bundled manifest (the committed real one)

    @Test("The bundled manifest parses and describes the turbo model exactly")
    func bundledManifestMatchesModel() throws {
        let manifest = try WhisperKitModelManifest.bundled()
        #expect(manifest.repo == repo)
        #expect(manifest.variant == variant)
        // The turbo variant is 24 files (4 .mlmodelc dirs + 2 top-level configs).
        #expect(manifest.assets.count == 24)
        // Every asset has a positive size and a non-empty path.
        #expect(manifest.assets.allSatisfy { $0.size > 0 && !$0.path.isEmpty })
        // The dominant file is the AudioEncoder weights (~1.27 GB).
        let biggest = manifest.assets.max { $0.size < $1.size }
        #expect(biggest?.path == "AudioEncoder.mlmodelc/weights/weight.bin")
        // Total matches the known on-disk footprint (drives BAMaxInstallSize).
        #expect(manifest.totalSize == 1638464446)
    }

    @Test("Manifest round-trips through its JSON encoding")
    func manifestRoundTrip() throws {
        let manifest = WhisperKitModelManifest(repo: repo, variant: variant, assets: [
            WhisperKitModelAsset(path: "config.json", size: 1149),
            WhisperKitModelAsset(path: "AudioEncoder.mlmodelc/model.mil", size: 7175750),
        ])
        let decoded = try WhisperKitModelManifest.decode(from: manifest.encoded())
        #expect(decoded == manifest)
    }
}
