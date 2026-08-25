// The `SessionIntelligence` message-mapping paths `SiriIntelligenceTests` doesn't reach:
// `IntelligenceUnavailable.other(_:)`, `errorMessage(for:)`'s non-`IntelligenceError` fallback,
// and `trimmedForContext`'s truncation. All pure string logic — no Apple Intelligence hardware
// involved (see `SessionIntelligence.swift`'s own doc comment on why the gate is injectable).

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("SessionIntelligence — message mapping")
struct SessionIntelligenceMessageMappingTests {
    @Test func otherCaseSurfacesItsOwnDetailVerbatim() {
        let reason = IntelligenceUnavailable.other("A custom platform-reported reason.")
        #expect(reason.message == "A custom platform-reported reason.")
    }

    @Test func errorMessageMapsEmptyTranscriptToAUserFacingSentence() {
        let message = SessionIntelligence.errorMessage(for: IntelligenceError.emptyTranscript)
        #expect(message == "That transcript is empty.")
    }

    @Test func errorMessageFallsBackForAnyUnrecognizedError() {
        struct SomeOtherError: Error {}
        let message = SessionIntelligence.errorMessage(for: SomeOtherError())
        #expect(message == "Something went wrong. Please try again.")
    }

    @Test func trimmedForContextPassesShortTranscriptsThroughUnchanged() {
        let short = "A short transcript."
        #expect(SessionIntelligence.trimmedForContext(short, maxCharacters: 12_000) == short)
    }

    @Test func trimmedForContextTruncatesAndMarksLongTranscripts() {
        let long = String(repeating: "x", count: 100)
        let trimmed = SessionIntelligence.trimmedForContext(long, maxCharacters: 40)
        #expect(trimmed.hasPrefix(String(repeating: "x", count: 40)))
        #expect(trimmed.hasSuffix("(transcript truncated)"))
        #expect(trimmed.count > 40)
    }
}
