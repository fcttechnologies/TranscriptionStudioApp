import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("TranscriptFuser attribution")
struct TranscriptFuserTests {

    // A segment fully inside one speaker's turn is attributed to that speaker with the
    // turn's confidence carried through.
    @Test func fullOverlapAttributes() {
        let asr = [AsrSegment(track: .mixed, start: 1, end: 3, text: "hello")]
        let turns = [SpeakerTurn(speakerIndex: 2, start: 0, end: 5, confidence: 0.8)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns)
        #expect(out.count == 1)
        #expect(out[0].speaker == .speaker(2))
        #expect(abs(out[0].speakerConfidence - 0.8) < 0.001)
        #expect(!out[0].isProvisional)
    }

    // When two speakers overlap a segment, the larger share of the segment wins.
    @Test func majorityOverlapWins() {
        let asr = [AsrSegment(track: .mixed, start: 0, end: 4, text: "handoff")]
        let turns = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 1, confidence: 0.9),
            SpeakerTurn(speakerIndex: 1, start: 1, end: 4, confidence: 0.9)
        ]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns)
        #expect(out[0].speaker == .speaker(1))
    }

    // No diarization coverage → unknown, zero confidence.
    @Test func noCoverageIsUnknown() {
        let asr = [AsrSegment(track: .mixed, start: 10, end: 12, text: "orphan")]
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 5, confidence: 0.9)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns)
        #expect(out[0].speaker == .unknown)
        #expect(out[0].speakerConfidence == 0)
    }

    // Coverage below the minimum threshold → unknown (a sliver of overlap is not a label).
    @Test func belowMinimumCoverageIsUnknown() {
        let asr = [AsrSegment(track: .mixed, start: 0, end: 10, text: "mostly uncovered")]
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 1, confidence: 0.9)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns, minimumCoverage: 0.3)
        #expect(out[0].speaker == .unknown)
    }

    // Meeting mode: microphone-track segments are Me, structurally, regardless of turns.
    @Test func micTrackIsMeInMeetingMode() {
        let asr = [AsrSegment(track: .microphone, start: 0, end: 2, text: "my line")]
        let turns = [SpeakerTurn(speakerIndex: 3, start: 0, end: 2, confidence: 0.99)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns, micIsMe: true)
        #expect(out[0].speaker == .me)
        #expect(out[0].speakerConfidence == 1)
    }

    // Meeting mode: system-track segments still go through the diarizer.
    @Test func systemTrackStillDiarizedInMeetingMode() {
        let asr = [AsrSegment(track: .system, start: 0, end: 2, text: "their line")]
        let turns = [SpeakerTurn(speakerIndex: 1, start: 0, end: 2, confidence: 0.7)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns, micIsMe: true)
        #expect(out[0].speaker == .speaker(1))
    }

    // A provisional (preview) turn marks the attribution provisional even when the ASR
    // text itself is confirmed.
    @Test func previewTurnMakesAttributionProvisional() {
        let asr = [AsrSegment(track: .mixed, start: 0, end: 2, text: "live", isConfirmed: true)]
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 2, confidence: 0.9, isCommitted: false)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns)
        #expect(out[0].speaker == .speaker(0))
        #expect(out[0].isProvisional)
    }

    // Unconfirmed ASR stays provisional even with committed turns.
    @Test func unconfirmedAsrIsProvisional() {
        let asr = [AsrSegment(track: .mixed, start: 0, end: 2, text: "still decoding", isConfirmed: false)]
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 2, confidence: 0.9)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns)
        #expect(out[0].isProvisional)
    }

    // Confidence scales with coverage: half-covered segment carries half the turn confidence.
    @Test func confidenceScalesWithCoverage() {
        let asr = [AsrSegment(track: .mixed, start: 0, end: 4, text: "half covered")]
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 2, confidence: 1.0)]
        let out = TranscriptFuser.attribute(asr: asr, turns: turns)
        #expect(out[0].speaker == .speaker(0))
        #expect(abs(out[0].speakerConfidence - 0.5) < 0.001)
    }
}
