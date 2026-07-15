// DiarizationBackend is the one seam callers use to pick a diarizer — these tests pin its
// enum-level contract (display names, which backend streams live, and which concrete engine
// each case builds) so a future case addition or default swap is caught if it drifts silently.

import Foundation
import Testing
@testable import TranscriptionKit

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

    @Test func makeEngineBuildsTheMatchingConcreteEngine() {
        let speakerKit = DiarizationBackend.speakerKit.makeEngine()
        #expect(speakerKit is SpeakerKitEngine)
        #expect(speakerKit.backendName == "SpeakerKit (Pyannote)")
        #expect(!speakerKit.supportsStreaming)

        let sortformer = DiarizationBackend.sortformer.makeEngine()
        #expect(sortformer is SortformerEngine)
        #expect(sortformer.backendName == "Sortformer (Core AI)")
        #expect(sortformer.supportsStreaming)
    }

    @Test func allCasesRawValuesRoundTripThroughCodable() throws {
        for backend in DiarizationBackend.allCases {
            let data = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(DiarizationBackend.self, from: data)
            #expect(decoded == backend)
        }
    }
}
