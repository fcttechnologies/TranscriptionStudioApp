// `SpeakerTurn.id` — the identifiability seam ForEach/SwiftUI diffing relies on. Every other
// test constructs `SpeakerTurn`s but never reads `.id`.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("SpeakerTurn identity")
struct SpeakerTurnIdentityTests {
    @Test func idEncodesSpeakerSpanAndCommitState() {
        let turn = SpeakerTurn(speakerIndex: 2, start: 1.5, end: 3.25, confidence: 0.8, isCommitted: true)
        #expect(turn.id == "2-1.5-3.25-true")
    }

    @Test func aPreviewTurnsIdDiffersFromTheSameSpanCommitted() {
        let committed = SpeakerTurn(speakerIndex: 0, start: 0, end: 1, confidence: 0.9, isCommitted: true)
        let preview = SpeakerTurn(speakerIndex: 0, start: 0, end: 1, confidence: 0.9, isCommitted: false)
        #expect(committed.id != preview.id)
    }
}
