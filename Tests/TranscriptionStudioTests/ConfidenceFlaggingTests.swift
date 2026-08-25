// The verbatim/confidence display's pure logic: `Confidence.wordScore` normalization and
// `Confidence.spans` per-word-vs-segment flagging with its clean degrade when word timestamps
// are absent. The view layer (`ConfidenceWordsText`) just renders these spans.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("Confidence flagging (verbatim/confidence mode)")
struct ConfidenceFlaggingTests {
    private let threshold: Float = 0.55

    @Test func wordScoreClampsToUnitInterval() {
        #expect(Confidence.wordScore(0.9) == 0.9)
        #expect(Confidence.wordScore(-0.2) == 0)
        #expect(Confidence.wordScore(1.4) == 1)
    }

    @Test func perWordSpansFlagOnlyTheLowConfidenceWords() {
        let words = [
            AsrWord(word: "The", start: 0, end: 0.2, probability: 0.98),
            AsrWord(word: " defendant", start: 0.2, end: 0.7, probability: 0.30),  // low
            AsrWord(word: " stated", start: 0.7, end: 1.0, probability: 0.91),
            AsrWord(word: " clearly", start: 1.0, end: 1.4, probability: 0.41),    // low
        ]
        let spans = Confidence.spans(text: "The defendant stated clearly",
                                     words: words, segmentScore: 0.9, threshold: threshold)

        #expect(spans.count == 4)
        #expect(spans.map(\.isLowConfidence) == [false, true, false, true])
        // The spans reconstruct the line verbatim — nothing dropped or cleaned.
        #expect(spans.map(\.text).joined() == "The defendant stated clearly")
    }

    @Test func boundaryProbabilityAtThresholdIsNotFlagged() {
        // `< threshold` is the flag rule, so a score exactly at the threshold reads as confident.
        let words = [AsrWord(word: "edge", start: 0, end: 0.3, probability: threshold)]
        let spans = Confidence.spans(text: "edge", words: words, segmentScore: 1, threshold: threshold)
        #expect(spans == [ConfidenceSpan(text: "edge", isLowConfidence: false)])
    }

    @Test func degradesToSingleSegmentSpanWhenNoWords() {
        // The common case: word timestamps off, so only the segment legibility score exists.
        let lowSegment = Confidence.spans(text: "muffled passage", words: nil,
                                          segmentScore: 0.2, threshold: threshold)
        #expect(lowSegment == [ConfidenceSpan(text: "muffled passage", isLowConfidence: true)])

        let clearSegment = Confidence.spans(text: "clean passage", words: nil,
                                            segmentScore: 0.8, threshold: threshold)
        #expect(clearSegment == [ConfidenceSpan(text: "clean passage", isLowConfidence: false)])
    }

    @Test func emptyWordsArrayAlsoDegradesToTheSegmentSpan() {
        let spans = Confidence.spans(text: "fallback", words: [],
                                     segmentScore: 0.1, threshold: threshold)
        #expect(spans == [ConfidenceSpan(text: "fallback", isLowConfidence: true)])
    }
}
