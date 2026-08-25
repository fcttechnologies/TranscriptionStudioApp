import Foundation
import Testing
import WhisperKit
@testable import TranscriptionStudio

/// Unit-tests the WhisperKit segment → `AsrSegment` mapping directly (no model download):
/// every confidence field survives, word timestamps convert, and the confirmed flag is
/// carried from the caller rather than inferred from the model output.
@Suite("WhisperKitAsrEngine — segment mapping")
struct WhisperKitAsrEngineMappingTests {

    @Test func mapsAllConfidenceFieldsAndTrimsText() {
        let whisperSegment = TranscriptionSegment(
            start: 1.5, end: 3.25, text: "  hello world  ",
            avgLogprob: -0.31, compressionRatio: 1.6, noSpeechProb: 0.04
        )
        let segment = WhisperKitAsrEngine.makeSegment(from: whisperSegment, track: .system, confirmed: true)

        #expect(segment.track == .system)
        #expect(segment.start == 1.5)
        #expect(segment.end == 3.25)
        #expect(segment.text == "hello world")
        #expect(segment.avgLogprob == -0.31)
        #expect(segment.compressionRatio == 1.6)
        #expect(segment.noSpeechProb == 0.04)
        #expect(segment.isConfirmed)
        #expect(segment.words == nil)
    }

    @Test func mapsWordTimestampsWhenPresent() throws {
        let words = [
            WordTiming(word: "hi", tokens: [1], start: 0, end: 0.4, probability: 0.95),
            WordTiming(word: "there", tokens: [2], start: 0.4, end: 0.9, probability: 0.88),
        ]
        let whisperSegment = TranscriptionSegment(start: 0, end: 0.9, text: "hi there", words: words)
        let segment = WhisperKitAsrEngine.makeSegment(from: whisperSegment, track: .mixed, confirmed: false)

        #expect(!segment.isConfirmed)
        let mappedWords = try #require(segment.words)
        #expect(mappedWords.count == 2)
        #expect(mappedWords[0].word == "hi")
        #expect(mappedWords[0].probability == 0.95)
        #expect(abs(mappedWords[1].start - 0.4) < 0.0001)
    }
}
