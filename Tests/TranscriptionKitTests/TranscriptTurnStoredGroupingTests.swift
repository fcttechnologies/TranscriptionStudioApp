// `TranscriptTurn.group(stored:)` — groups a saved session's `StoredSegment`s (library history
// playback) into consecutive same-speaker turns. `TranscriptRenderingTests.swift` covers
// `group(_: [AttributedSegment])` (the live path) but never this one, which the session
// detail/history view uses instead.

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("TranscriptTurn.group(stored:)")
struct TranscriptTurnStoredGroupingTests {
    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String,
                         speaker: SpeakerID) -> StoredSegment {
        let s = StoredSegment(start: start, end: end, text: text)
        s.speaker = speaker
        return s
    }

    @Test func consecutiveSameSpeakerSegmentsMergeIntoOneTurn() {
        let segments = [
            segment(0, 2, "Hello.", speaker: .speaker(0)),
            segment(2, 4, "How are you?", speaker: .speaker(0)),
        ]
        let turns = TranscriptTurn.group(stored: segments)
        #expect(turns.count == 1)
        #expect(turns[0].lines.map(\.text) == ["Hello.", "How are you?"])
        #expect(turns[0].speaker == .speaker(0))
    }

    @Test func aSpeakerChangeStartsANewTurn() {
        let segments = [
            segment(0, 2, "Hi.", speaker: .speaker(0)),
            segment(2, 4, "Hey.", speaker: .speaker(1)),
        ]
        let turns = TranscriptTurn.group(stored: segments)
        #expect(turns.count == 2)
        #expect(turns[0].speaker == .speaker(0))
        #expect(turns[1].speaker == .speaker(1))
    }

    @Test func segmentsAreRegroupedInTimeOrderRegardlessOfInputOrder() {
        // Out-of-order input (as a fetch without a sort might hand back) is sorted by start
        // before grouping, so an interleaved same-speaker pair still merges into one turn.
        let segments = [
            segment(2, 4, "second", speaker: .speaker(0)),
            segment(0, 2, "first", speaker: .speaker(0)),
        ]
        let turns = TranscriptTurn.group(stored: segments)
        #expect(turns.count == 1)
        #expect(turns[0].lines.map(\.text) == ["first", "second"])
    }

    @Test func everyLineIsNeverProvisionalForStoredHistory() {
        let turns = TranscriptTurn.group(stored: [segment(0, 1, "done", speaker: .me)])
        #expect(turns[0].isProvisional == false)
        #expect(turns[0].lines[0].isProvisional == false)
    }

    @Test func emptyInputProducesNoTurns() {
        #expect(TranscriptTurn.group(stored: []).isEmpty)
    }
}
