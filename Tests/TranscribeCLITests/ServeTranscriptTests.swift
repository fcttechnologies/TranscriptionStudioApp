// `ServeTranscript` — the fusion a job's result is built from. Pure: no engines, no sockets.
//
// The rule under test is what separation is allowed to show. It runs on every job, but a
// result only ever carries speaker labels when the fusion actually distinguished more than one
// voice, so a solo clip reads as plain prose.

import Foundation
import Testing
@testable import transcribe_cli

private func asr(_ start: Double, _ end: Double, _ text: String) -> AsrSegment {
    AsrSegment(track: .mixed, start: start, end: end, text: text)
}

private func turn(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerTurn {
    SpeakerTurn(speakerIndex: speaker, start: start, end: end, confidence: 0.9)
}

@Suite("ServeTranscript")
struct ServeTranscriptTests {

    // MARK: one voice

    @Test func oneVoiceCarriesNoLabelsAndReadsAsProse() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "Good morning."), asr(2, 4, "Here is the update.")],
            turns: [turn(0, 0, 4)])

        #expect(result.segments.allSatisfy { $0.speaker == nil })
        #expect(result.transcript == "Good morning. Here is the update.")
    }

    /// Separation that could not run at all is the same result as separation that heard one
    /// voice — the transcript is what it would have been without it.
    @Test func noTurnsAtAllReadsAsProse() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "Good morning."), asr(2, 4, "Here is the update.")],
            turns: [])

        #expect(result.segments.allSatisfy { $0.speaker == nil })
        #expect(result.transcript == "Good morning. Here is the update.")
    }

    /// The count that decides labelling is the one the RESULT distinguished, not the one the
    /// diarizer reported: a turn in a gap no segment overlaps would otherwise put a
    /// `Speaker 1:` prefix on every line of a clip that reads as one voice.
    @Test func aSecondSpeakerNoSegmentWonStillReadsAsProse() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "Good morning."), asr(6, 8, "Here is the update.")],
            turns: [turn(0, 0, 2), turn(1, 3, 5), turn(0, 6, 8)])

        #expect(result.segments.allSatisfy { $0.speaker == nil })
        #expect(result.transcript == "Good morning. Here is the update.")
    }

    // MARK: more than one voice

    @Test func twoVoicesLabelTheirSegmentsAndPrefixTheirLines() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "Good morning."), asr(2, 4, "Happy to be here.")],
            turns: [turn(0, 0, 2), turn(1, 2, 4)])

        #expect(result.segments.map(\.speaker) == [1, 2])
        #expect(result.transcript == "Speaker 1: Good morning.\nSpeaker 2: Happy to be here.")
    }

    /// The wire label is 1-based so it reads as the `Speaker N` beside it — the two must never
    /// disagree about who is who.
    @Test func labelsAreOneBasedAndMatchTheRenderedName() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "First."), asr(2, 4, "Second.")],
            turns: [turn(0, 0, 2), turn(1, 2, 4)])

        for segment in result.segments {
            let speaker = try! #require(segment.speaker)
            #expect(result.transcript.contains("Speaker \(speaker): \(segment.text)"))
        }
    }

    @Test func consecutiveSegmentsFromOneSpeakerShareALine() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "Good morning."), asr(2, 4, "Thanks for joining."),
                  asr(4, 6, "Happy to be here.")],
            turns: [turn(0, 0, 4), turn(1, 4, 6)])

        #expect(result.transcript == """
            Speaker 1: Good morning. Thanks for joining.
            Speaker 2: Happy to be here.
            """)
    }

    /// A segment separation never covered is named as such rather than folded into whichever
    /// neighbour it sits beside, and carries no label to be wrong about.
    @Test func anUncoveredSegmentIsUnknownAndUnlabelled() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2, "Good morning."), asr(2, 4, "…music…"), asr(4, 6, "Happy to be here.")],
            turns: [turn(0, 0, 2), turn(1, 4, 6)])

        #expect(result.segments.map(\.speaker) == [1, nil, 2])
        #expect(result.transcript == """
            Speaker 1: Good morning.
            Unknown: …music…
            Speaker 2: Happy to be here.
            """)
    }

    @Test func segmentTimingsSurviveTheFusion() {
        let result = ServeTranscript.build(
            asr: [asr(0, 2.5, "Good morning."), asr(2.5, 4, "Happy to be here.")],
            turns: [turn(0, 0, 2.5), turn(1, 2.5, 4)])

        #expect(result.segments.map(\.start) == [0, 2.5])
        #expect(result.segments.map(\.end) == [2.5, 4])
    }

    // MARK: the wire form

    @Test func onlyALabelledSegmentCarriesASpeakerKey() {
        let labelled = ServeTranscript.build(
            asr: [asr(0, 2, "One."), asr(2, 4, "Two.")],
            turns: [turn(0, 0, 2), turn(1, 2, 4)]).segments.jsonArray
        let solo = ServeTranscript.build(
            asr: [asr(0, 2, "One."), asr(2, 4, "Two.")],
            turns: [turn(0, 0, 4)]).segments.jsonArray

        #expect(labelled.allSatisfy { $0["speaker"] as? Int != nil })
        #expect(solo.allSatisfy { $0["speaker"] == nil })
        #expect(solo.allSatisfy { $0["start"] != nil && $0["end"] != nil && $0["text"] != nil })
    }
}
