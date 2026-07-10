import Foundation
import Testing
@testable import TranscriptionKit

@Suite("Transcript export formatting")
struct TranscriptExportTests {
    private let items = [
        TranscriptExport.Item(speaker: "Me", start: 0, end: 3.2, text: "Good morning everyone."),
        TranscriptExport.Item(speaker: "Speaker 2", start: 3.2, end: 7.85, text: "Happy to be here."),
        TranscriptExport.Item(speaker: "Speaker 2", start: 7.85, end: 12, text: "I reviewed the proposal."),
    ]

    @Test func plainTextCarriesSpeakers() {
        let out = TranscriptExport.render(items, as: .plainText)
        #expect(out == """
        Me: Good morning everyone.
        Speaker 2: Happy to be here.
        Speaker 2: I reviewed the proposal.
        """)
    }

    @Test func plainTextWithoutSpeakersIsUnprefixed() {
        let bare = items.map { TranscriptExport.Item(speaker: nil, start: $0.start, end: $0.end, text: $0.text) }
        let out = TranscriptExport.render(bare, as: .plainText)
        #expect(out == "Good morning everyone.\nHappy to be here.\nI reviewed the proposal.")
    }

    @Test func srtNumbersAndTimesCues() {
        let out = TranscriptExport.render(items, as: .srt)
        #expect(out.hasPrefix("""
        1
        00:00:00,000 --> 00:00:03,200
        Me: Good morning everyone.

        2
        00:00:03,200 --> 00:00:07,850
        """))
        #expect(out.hasSuffix("\n"))
    }

    @Test func vttHasHeaderAndVoiceTags() {
        let out = TranscriptExport.render(items, as: .vtt)
        #expect(out.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:03.200\n<v Me>Good morning everyone."))
    }

    @Test func markdownGroupsConsecutiveSpeakerLines() {
        let out = TranscriptExport.render(items, as: .markdown, title: "Sync")
        #expect(out.contains("# Sync"))
        // Speaker 2's two consecutive lines share one header.
        #expect(out.components(separatedBy: "**Speaker 2**").count == 2)
    }

    @Test func timestampsRollPastAnHour() {
        #expect(TranscriptExport.srtTime(3661.5) == "01:01:01,500")
        #expect(TranscriptExport.vttTime(3661.5) == "01:01:01.500")
    }

    @Test func sessionItemsHideSpeakersWhenAllUnknown() {
        let session = TranscriptSession(title: "File", kind: .fileTranscription)
        let a = StoredSegment(start: 0, end: 2, text: "Hello there.")
        let b = StoredSegment(start: 2, end: 4, text: "General greeting.")
        session.segments = [a, b]
        let items = TranscriptExport.items(from: session)
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.speaker == nil })
    }

    @Test func sessionItemsShowSpeakersWhenAttributed() {
        let session = TranscriptSession(title: "Meeting", kind: .meetingRecording)
        let a = StoredSegment(start: 0, end: 2, text: "Hello.")
        a.speaker = .me
        let b = StoredSegment(start: 2, end: 4, text: "Hi.")
        b.speaker = .speaker(1)
        session.segments = [b, a]   // intentionally unsorted
        let items = TranscriptExport.items(from: session)
        #expect(items.map(\.speaker) == ["Me", "Speaker 2"])
        #expect(items.first?.start == 0)
    }
}
