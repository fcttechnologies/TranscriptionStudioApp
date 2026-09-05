import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("Transcript rendering logic")
struct TranscriptRenderingTests {

    private func segment(_ speaker: SpeakerID, start: TimeInterval, text: String,
                         provisional: Bool = false) -> AttributedSegment {
        AttributedSegment(asr: AsrSegment(track: .mixed, start: start, end: start + 2, text: text,
                                          avgLogprob: -0.2,
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
                              avgLogprob: -0.1)
        let poor = AsrSegment(track: .mixed, start: 0, end: 1, text: "muddy",
                              avgLogprob: -2.0)
        #expect(Confidence.asrScore(good) > Confidence.asrScore(poor))
        #expect(Confidence.asrScore(good) <= 1)
        #expect(Confidence.asrScore(poor) >= 0)
    }

    @Test func clockFormatsMinutesAndHours() {
        #expect(TimeFormat.clock(65) == "01:05")
        #expect(TimeFormat.clock(3661) == "1:01:01")
    }





}
