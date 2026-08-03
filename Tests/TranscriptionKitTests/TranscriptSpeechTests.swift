// TranscriptSpeech — the pure text layer of read-aloud: the spoken rendition (mirroring the
// copy-transcript rule) and the passage split that bounds a long transcript's memory.

import Foundation
import Testing
@testable import TranscriptionKit

@Suite("TranscriptSpeech — spoken rendition")
struct TranscriptSpeechTextTests {
    private func turn(_ speaker: SpeakerID, _ lines: [String], startingAt start: TimeInterval = 0) -> TranscriptTurn {
        TranscriptTurn(id: "\(speaker)-\(start)", speaker: speaker, speakerConfidence: 1, start: start,
                       lines: lines.enumerated().map { index, text in
                           TranscriptTurn.Line(id: "\(speaker)-\(start)-\(index)", text: text,
                                               start: start + Double(index), isProvisional: false, asrScore: 1)
                       },
                       isProvisional: false)
    }

    @Test func aSingleVoiceReadsAsCleanParagraphsWithoutSpeakerLabels() {
        let turns = [turn(.speaker(0), ["First thought.", "Second thought."])]
        #expect(TranscriptSpeech.text(for: turns) == "First thought.\nSecond thought.")
    }

    @Test func severalVoicesKeepTheirSpeakerNames() {
        let turns = [turn(.speaker(0), ["Shall we start?"]),
                     turn(.speaker(1), ["Yes.", "Let's go."], startingAt: 5)]
        let text = TranscriptSpeech.text(for: turns)
        #expect(text == "\(SpeakerID.speaker(0).displayName): Shall we start?\n\(SpeakerID.speaker(1).displayName): Yes. Let's go.")
    }

    @Test func noTurnsSpeaksNothing() {
        #expect(TranscriptSpeech.text(for: []) == "")
        #expect(TranscriptSpeech.passages(from: "   \n  ") == [])
    }
}

@Suite("TranscriptSpeech — passage split")
struct TranscriptSpeechPassageTests {
    @Test func shortTextIsOnePassage() {
        #expect(TranscriptSpeech.passages(from: "One short line.", limit: 100) == ["One short line."])
    }

    @Test func splitsOnSentenceBoundariesAndPreservesEveryWord() {
        let sentences = (1...20).map { "Sentence number \($0) has a few words in it." }
        let text = sentences.joined(separator: " ")
        let passages = TranscriptSpeech.passages(from: text, limit: 120)

        #expect(passages.count > 1)
        #expect(passages.allSatisfy { $0.count <= 120 })
        // Every passage ends at a sentence boundary…
        #expect(passages.allSatisfy { $0.hasSuffix(".") })
        // …and reassembling them loses nothing.
        #expect(passages.joined(separator: " ") == text)
    }

    @Test func aDecimalNumberIsNotASentenceBoundary() {
        let text = "The rate was 3.5 percent for the year. " + String(repeating: "More words here. ", count: 10)
        let passages = TranscriptSpeech.passages(from: text, limit: 60)
        // "3.5" must never end a passage — the cut after "3." would if the dot counted.
        #expect(passages.allSatisfy { !$0.hasSuffix("3.") })
        #expect(passages.first?.contains("3.5") == true)
    }

    @Test func fallsBackToWordBoundariesWhenNoSentenceEndsInTheWindow() {
        let text = (1...40).map { "word\($0)" }.joined(separator: " ")
        let passages = TranscriptSpeech.passages(from: text, limit: 50)

        #expect(passages.count > 1)
        #expect(passages.allSatisfy { $0.count <= 50 })
        // Word-boundary cuts: no passage starts or ends mid-word.
        #expect(passages.joined(separator: " ") == text)
    }

    @Test func anUnbrokenRunIsHardCutAtTheLimit() {
        let text = String(repeating: "a", count: 120)
        let passages = TranscriptSpeech.passages(from: text, limit: 50)
        #expect(passages == [String(repeating: "a", count: 50),
                             String(repeating: "a", count: 50),
                             String(repeating: "a", count: 20)])
    }

    @Test func newlinesArePreferredBoundaries() {
        let paragraph = String(repeating: "x", count: 30)
        let text = Array(repeating: paragraph, count: 5).joined(separator: "\n")
        let passages = TranscriptSpeech.passages(from: text, limit: 70)
        #expect(passages.allSatisfy { !$0.contains(where: \.isNewline) || $0.count <= 70 })
        #expect(passages.flatMap { $0.split(separator: "\n") }.count == 5)
    }
}
