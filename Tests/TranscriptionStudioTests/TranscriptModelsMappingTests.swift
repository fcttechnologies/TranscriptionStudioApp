// `TranscriptSession.kind`'s raw-value round trip and `StoredSegment(from:)`'s word-timestamp
// JSON encoding — the two `TranscriptModels.swift` paths `JobAndInspectorTests`'
// `storedSegmentRoundTrip` doesn't touch (it only sets `.speaker`, never `.kind`, and its
// `AsrSegment` carries no `words`).

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("TranscriptSession.kind + StoredSegment word encoding")
struct TranscriptModelsMappingTests {
    @Test func kindSetterUpdatesTheUnderlyingRawValue() {
        let session = TranscriptSession(title: "Test", kind: .fileTranscription)
        #expect(session.kindRaw == SessionKind.fileTranscription.rawValue)

        session.kind = .meetingRecording
        #expect(session.kindRaw == SessionKind.meetingRecording.rawValue)
        #expect(session.kind == .meetingRecording)
    }

    @Test func storedSegmentEncodesWordTimestampsWhenPresent() throws {
        let words = [
            AsrWord(word: "hi", start: 0, end: 0.4, probability: 0.95),
            AsrWord(word: "there", start: 0.4, end: 0.9, probability: 0.88),
        ]
        let attributed = AttributedSegment(
            asr: AsrSegment(track: .mixed, start: 0, end: 0.9, text: "hi there", words: words),
            speaker: .unknown, speakerConfidence: 0, isProvisional: false)

        let stored = StoredSegment(from: attributed)
        let data = try #require(stored.wordsJSON)
        let decoded = try JSONDecoder().decode([AsrWord].self, from: data)
        #expect(decoded == words)
    }

    @Test func storedSegmentLeavesWordsJSONNilWhenNoWordTimestampsWereCaptured() {
        let attributed = AttributedSegment(
            asr: AsrSegment(track: .mixed, start: 0, end: 1, text: "no words"),
            speaker: .unknown, speakerConfidence: 0, isProvisional: false)
        let stored = StoredSegment(from: attributed)
        #expect(stored.wordsJSON == nil)
    }
}
