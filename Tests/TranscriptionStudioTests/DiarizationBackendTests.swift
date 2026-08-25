// DiarizationBackend is the one seam callers use to pick a diarizer — these tests pin its
// enum-level contract (display names, which backend streams live, and which concrete engine
// each case builds) so a future case addition or default swap is caught if it drifts silently.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("DiarizationBackend — selection")
struct DiarizationBackendTests {

    @Test func defaultBackendIsSortformer() {
        #expect(DiarizationBackend.default == .sortformer)
    }

    @Test func onlySortformerSupportsStreaming() {
        #expect(DiarizationBackend.sortformer.supportsStreaming)
        #expect(!DiarizationBackend.speakerKit.supportsStreaming)
    }

    @Test func displayNamesAreDistinctAndHumanReadable() {
        #expect(DiarizationBackend.speakerKit.displayName == "SpeakerKit (Pyannote)")
        #expect(DiarizationBackend.sortformer.displayName == "Sortformer (Core AI)")
        #expect(DiarizationBackend.allCases.map(\.displayName).count
                == Set(DiarizationBackend.allCases.map(\.displayName)).count)
    }

    /// A temp store whose local re-export manifest is present (safe to load Sortformer) or absent.
    private func tempStore(withManifest: Bool) throws -> SortformerModelStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if withManifest {
            let json = #"{"files":[{"name":"x","bytes":1}]}"#
            try json.data(using: .utf8)!.write(to: root.appendingPathComponent(SortformerManifest.filename))
        }
        return SortformerModelStore(root: root)
    }

    @Test func makeEngineBuildsTheMatchingConcreteEngine() throws {
        let speakerKit = DiarizationBackend.speakerKit.makeEngine()
        #expect(speakerKit is SpeakerKitEngine)
        #expect(speakerKit.backendName == "SpeakerKit (Pyannote)")
        #expect(!speakerKit.supportsStreaming)

        // Sortformer builds its real engine only when a re-exported model is staged (manifest present).
        let sortformer = DiarizationBackend.sortformer.makeEngine(sortformerStore: try tempStore(withManifest: true))
        #expect(sortformer is SortformerEngine)
        #expect(sortformer.backendName == "Sortformer (Core AI)")
        #expect(sortformer.supportsStreaming)
    }

    @Test func sortformerFallsBackToSpeakerKitWithoutLocalManifest() throws {
        // The published Sortformer model FATALLY (uncatchably) aborts on load; with no local
        // re-export manifest the guard must avoid it and hand back SpeakerKit, not crash.
        let engine = DiarizationBackend.sortformer.makeEngine(sortformerStore: try tempStore(withManifest: false))
        #expect(engine is SpeakerKitEngine)
    }

    @Test func allCasesRawValuesRoundTripThroughCodable() throws {
        for backend in DiarizationBackend.allCases {
            let data = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(DiarizationBackend.self, from: data)
            #expect(decoded == backend)
        }
    }
}
