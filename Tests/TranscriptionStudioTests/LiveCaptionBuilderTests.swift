import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("LiveCaptionBuilder windowing / formatting / speaker labels")
struct LiveCaptionBuilderTests {

    /// Build an attributed segment the way the fused live stream does — a bit of ASR text with a
    /// resolved speaker. Non-overlapping default spans so ids stay distinct.
    private func seg(_ text: String,
                     speaker: SpeakerID = .speaker(0),
                     start: TimeInterval,
                     end: TimeInterval? = nil,
                     provisional: Bool = false) -> AttributedSegment {
        let asr = AsrSegment(track: .mixed, start: start, end: end ?? start + 1, text: text,
                             isConfirmed: !provisional)
        return AttributedSegment(asr: asr, speaker: speaker,
                                 speakerConfidence: speaker == .unknown ? 0 : 0.9,
                                 isProvisional: provisional)
    }

    // Consecutive same-speaker segments accumulate into one caption line, words joined and
    // per-segment whitespace trimmed to single spaces.
    @Test func sameSpeakerSegmentsAccumulateIntoOneLine() {
        let segments = [
            seg(" hello", start: 0),
            seg("there ", start: 1),
            seg(" friend", start: 2),
        ]
        let lines = LiveCaptionBuilder.lines(from: segments, showsSpeakers: true)
        #expect(lines.count == 1)
        #expect(lines[0].text == "hello there friend")
    }

    // Distinct speakers break into separate caption lines, each labeled with its display name.
    @Test func distinctSpeakersAreSeparateLabeledLines() {
        let segments = [
            seg("morning", speaker: .speaker(0), start: 0),
            seg("morning to you", speaker: .speaker(1), start: 1),
        ]
        let lines = LiveCaptionBuilder.lines(from: segments, showsSpeakers: true)
        #expect(lines.count == 2)
        #expect(lines[0].speakerLabel == "Speaker 1")
        #expect(lines[1].speakerLabel == "Speaker 2")
        #expect(lines[1].text == "morning to you")
    }

    // The "Me" speaker (structural mic attribution) carries the Me label.
    @Test func meSpeakerIsLabeledMe() {
        let lines = LiveCaptionBuilder.lines(from: [seg("my turn", speaker: .me, start: 0)],
                                             showsSpeakers: true)
        #expect(lines[0].speakerLabel == "Me")
        #expect(lines[0].speaker == .me)
    }

    // showsSpeakers=false (diarizer unavailable) degrades to one unlabeled flow — no labels,
    // and same-speaker-by-default segments collapse into a single line.
    @Test func degradesToUnlabeledFlowWhenSpeakersOff() {
        let segments = [
            seg("one", speaker: .me, start: 0),
            seg("two", speaker: .speaker(1), start: 1),
        ]
        let lines = LiveCaptionBuilder.lines(from: segments, showsSpeakers: false)
        for line in lines { #expect(line.speakerLabel == nil) }
    }

    // Unknown (unattributed) spans never get a label even with speakers on — clean degrade.
    @Test func unknownSpeakerHasNoLabel() {
        let lines = LiveCaptionBuilder.lines(from: [seg("orphan", speaker: .unknown, start: 0)],
                                             showsSpeakers: true)
        #expect(lines[0].speakerLabel == nil)
        #expect(lines[0].speaker == .unknown)
    }

    // Windowing bounds the stage to the most-recent segments, including the newest text.
    @Test func windowsToMostRecentSegments() {
        // 10 distinct-speaker segments so each is its own turn; window keeps the last 3.
        let segments = (0..<10).map { i in
            seg("word\(i)", speaker: .speaker(i % 4), start: TimeInterval(i))
        }
        let lines = LiveCaptionBuilder.lines(from: segments, maxSegments: 3, showsSpeakers: true)
        #expect(lines.count == 3)
        #expect(lines.last?.text == "word9")
        #expect(lines.first?.text == "word7")
    }

    // A continuous single speaker can't grow one unbounded line — windowing still trims the
    // oldest words off the front even though it's all one turn.
    @Test func singleSpeakerLineIsBoundedByWindow() {
        let segments = (0..<8).map { i in seg("w\(i)", speaker: .speaker(0), start: TimeInterval(i)) }
        let lines = LiveCaptionBuilder.lines(from: segments, maxSegments: 3, showsSpeakers: true)
        #expect(lines.count == 1)
        #expect(lines[0].text == "w5 w6 w7")
    }

    // The provisional tail marks its caption line provisional (dimmed treatment in the view).
    @Test func provisionalTailMarksLineProvisional() {
        let segments = [
            seg("settled", speaker: .speaker(0), start: 0),
            seg("still coming", speaker: .speaker(0), start: 1, provisional: true),
        ]
        let lines = LiveCaptionBuilder.lines(from: segments, showsSpeakers: true)
        #expect(lines.count == 1)
        #expect(lines[0].isProvisional)
    }

    // Empty input → no caption lines (the view shows its "Listening…" state).
    @Test func emptyInputYieldsNoLines() {
        #expect(LiveCaptionBuilder.lines(from: [], showsSpeakers: true).isEmpty)
    }

    // A zero/negative window is clamped to at least one segment (never an out-of-range slice).
    @Test func nonPositiveWindowClampsToOne() {
        let segments = [seg("a", start: 0), seg("b", speaker: .speaker(1), start: 1)]
        let lines = LiveCaptionBuilder.lines(from: segments, maxSegments: 0, showsSpeakers: true)
        #expect(lines.count == 1)
        #expect(lines[0].text == "b")
    }
}
