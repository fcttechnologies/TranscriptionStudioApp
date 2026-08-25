import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("Transcript rendering logic")
struct TranscriptRenderingTests {

    private func segment(_ speaker: SpeakerID, start: TimeInterval, text: String,
                         provisional: Bool = false) -> AttributedSegment {
        AttributedSegment(asr: AsrSegment(track: .mixed, start: start, end: start + 2, text: text,
                                          avgLogprob: -0.2, noSpeechProb: 0.02, compressionRatio: 1.3,
                                          isConfirmed: !provisional),
                          speaker: speaker, speakerConfidence: 0.9, isProvisional: provisional)
    }

    @Test func consecutiveSameSpeakerSegmentsGroupIntoOneTurn() {
        let segments = [
            segment(.speaker(0), start: 0, text: "one"),
            segment(.speaker(0), start: 2, text: "two"),
            segment(.speaker(1), start: 4, text: "three"),
        ]
        let turns = TranscriptTurn.group(segments)
        #expect(turns.count == 2)
        #expect(turns[0].lines.count == 2)
        #expect(turns[0].speaker == .speaker(0))
        #expect(turns[1].speaker == .speaker(1))
    }

    @Test func provisionalPropagatesToTurn() {
        let turns = TranscriptTurn.group([
            segment(.speaker(0), start: 0, text: "committed"),
            segment(.speaker(0), start: 2, text: "live", provisional: true),
        ])
        #expect(turns.count == 1)
        #expect(turns[0].isProvisional)
    }

    @Test func asrScoreRewardsHighLikelihoodPenalizesNoSpeech() {
        let good = AsrSegment(track: .mixed, start: 0, end: 1, text: "clear",
                              avgLogprob: -0.1, noSpeechProb: 0.01, compressionRatio: 1.2)
        let poor = AsrSegment(track: .mixed, start: 0, end: 1, text: "muddy",
                              avgLogprob: -2.0, noSpeechProb: 0.6, compressionRatio: 2.5)
        #expect(Confidence.asrScore(good) > Confidence.asrScore(poor))
        #expect(Confidence.asrScore(good) <= 1)
        #expect(Confidence.asrScore(poor) >= 0)
    }

    @Test func clockFormatsMinutesAndHours() {
        #expect(TimeFormat.clock(65) == "01:05")
        #expect(TimeFormat.clock(3661) == "1:01:01")
    }

    @Test func abFrameAgreementIsPerfectForIdenticalTimelines() {
        let turns = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 4, confidence: 0.9),
            SpeakerTurn(speakerIndex: 1, start: 4, end: 8, confidence: 0.9),
        ]
        let score = InspectorDiarizerAB.frameAgreement(turns, turns, duration: 8)
        #expect(score > 0.99)
    }

    @Test func abFrameAgreementIsZeroForCompletelySwappedSpeakers() {
        // Every frame's dominant speaker differs between the two timelines end to end.
        let a = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 4, confidence: 0.9),
            SpeakerTurn(speakerIndex: 1, start: 4, end: 8, confidence: 0.9),
        ]
        let b = [
            SpeakerTurn(speakerIndex: 1, start: 0, end: 4, confidence: 0.9),
            SpeakerTurn(speakerIndex: 0, start: 4, end: 8, confidence: 0.9),
        ]
        let score = InspectorDiarizerAB.frameAgreement(a, b, duration: 8)
        #expect(score < 0.01)
    }

    @Test func abFrameAgreementIsPartialForOverlappingButNotIdenticalTimelines() {
        // The second half disagrees; the first half agrees — expect ~50%.
        let a = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 4, confidence: 0.9),
            SpeakerTurn(speakerIndex: 1, start: 4, end: 8, confidence: 0.9),
        ]
        let b = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 4, confidence: 0.9),
            SpeakerTurn(speakerIndex: 0, start: 4, end: 8, confidence: 0.9),
        ]
        let score = InspectorDiarizerAB.frameAgreement(a, b, duration: 8)
        #expect(score > 0.45 && score < 0.55)
    }

    @Test func abFrameAgreementIsZeroForZeroDuration() {
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 1, confidence: 0.9)]
        #expect(InspectorDiarizerAB.frameAgreement(turns, turns, duration: 0) == 0)
    }

    @Test func abFrameAgreementAgreesOnSilenceWhenBothTimelinesAreEmpty() {
        // No turns at all in either timeline: both sides are "no speaker" (nil == nil) at
        // every frame, so this counts as full agreement rather than zero.
        let score = InspectorDiarizerAB.frameAgreement([], [], duration: 4)
        #expect(score > 0.99)
    }
}
