// The detail view's pure layout + playhead logic: the conditional speaker-grouping decision
// (single voice = flat, several = grouped) and the playhead→line mapping the karaoke
// highlight rides on. Container-free and deterministic.

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("TranscriptLayoutMode — the flat-vs-grouped decision")
struct TranscriptLayoutModeTests {
    private func turn(_ speaker: SpeakerID, at start: TimeInterval = 0) -> TranscriptTurn {
        TranscriptTurn(id: UUID().uuidString, speaker: speaker, speakerConfidence: 1,
                       start: start, lines: [], isProvisional: false)
    }

    @Test func anEmptyTranscriptIsFlat() {
        #expect(TranscriptLayoutMode.decide(turns: []) == .flat)
    }

    @Test func aSingleSpeakerIsFlat() {
        // One diarized voice across several turns — the Voice Memos single-speaker layout.
        let turns = [turn(.speaker(0)), turn(.speaker(0), at: 10), turn(.speaker(0), at: 20)]
        #expect(TranscriptLayoutMode.decide(turns: turns) == .flat)
    }

    @Test func anEntirelyUnattributedTranscriptIsFlat() {
        // No diarization coverage at all reads as one voice — labels would add nothing.
        let turns = [turn(.unknown), turn(.unknown, at: 10)]
        #expect(TranscriptLayoutMode.decide(turns: turns) == .flat)
    }

    @Test func onlyTheLocalUserIsFlat() {
        #expect(TranscriptLayoutMode.decide(turns: [turn(.me)]) == .flat)
    }

    @Test func twoDiarizedSpeakersAreGrouped() {
        let turns = [turn(.speaker(0)), turn(.speaker(1), at: 10)]
        #expect(TranscriptLayoutMode.decide(turns: turns) == .grouped)
    }

    @Test func theLocalUserPlusASpeakerIsGrouped() {
        // Meeting mode: "Me" + a diarized voice are two speakers to distinguish.
        let turns = [turn(.me), turn(.speaker(0), at: 10)]
        #expect(TranscriptLayoutMode.decide(turns: turns) == .grouped)
    }

    @Test func attributedPlusUnattributedIsGrouped() {
        // A mix of covered and uncovered spans keeps the labels, so the reader can tell
        // which blocks the diarizer actually attributed.
        let turns = [turn(.speaker(0)), turn(.unknown, at: 10)]
        #expect(TranscriptLayoutMode.decide(turns: turns) == .grouped)
    }
}

@Suite("PlayheadMapper — playhead → playing line")
struct PlayheadMapperTests {
    private let lines: [(id: String, start: TimeInterval)] = [
        (id: "a", start: 0),
        (id: "b", start: 5),
        (id: "c", start: 12.5),
    ]

    @Test func beforeTheFirstLineNothingPlays() {
        #expect(PlayheadMapper.lineID(at: -1, lineStarts: lines) == nil)
    }

    @Test func atZeroTheFirstLinePlays() {
        #expect(PlayheadMapper.lineID(at: 0, lineStarts: lines) == "a")
    }

    @Test func midLineMapsToThatLine() {
        #expect(PlayheadMapper.lineID(at: 7.3, lineStarts: lines) == "b")
    }

    @Test func anExactBoundaryLightsTheStartingLine() {
        #expect(PlayheadMapper.lineID(at: 5, lineStarts: lines) == "b")
    }

    @Test func aSeekJustShortOfABoundaryLightsTheComingLine() {
        // The tolerance: tap-to-seek lands a hair before the stamped start; the tapped line
        // should light, not its predecessor.
        #expect(PlayheadMapper.lineID(at: 12.46, lineStarts: lines) == "c")
    }

    @Test func justOutsideTheToleranceStaysOnThePreviousLine() {
        #expect(PlayheadMapper.lineID(at: 12.4, lineStarts: lines) == "b")
    }

    @Test func pastTheLastLineTheLastLinePlays() {
        #expect(PlayheadMapper.lineID(at: 1_000, lineStarts: lines) == "c")
    }

    @Test func anEmptyTranscriptMapsToNothing() {
        #expect(PlayheadMapper.lineID(at: 3, lineStarts: []) == nil)
    }
}
