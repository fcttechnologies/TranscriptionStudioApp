import AppIntents
import Foundation
import UniformTypeIdentifiers
import Testing
@testable import TranscriptionKit

/// `ExportTranscriptIntent` returns an `ExportedTranscriptFileEntity` so the exported file carries
/// an ownership signal. The load-bearing, wrong-fix-would-break facts: the ownership state (an
/// export leaves the app → `.shared`), the file content types it advertises, and that its query
/// round-trips a title from a file identifier.
struct ExportedTranscriptEntityTests {
    @Test func exportedFileIsMarkedShared() throws {
        let url = URL(fileURLWithPath: "/tmp/x/Standup.txt")
        let entity = try ExportedTranscriptFileEntity(id: .file(url: url), title: "Standup")
        // An exported transcript is shared outside the app, so Siri confirms before auto-sharing.
        #expect(entity.ownership == .shared)
    }

    @Test func supportedContentTypesCoverEveryExportFormat() {
        let types = ExportedTranscriptFileEntity.supportedContentTypes
        #expect(types.count == TranscriptExport.Format.allCases.count)
        #expect(types.contains(.plainText))
    }

    @Test func queryReconstructsTitleFromFileIdentifier() async throws {
        let url = URL(fileURLWithPath: "/tmp/exports/Quarterly Review.srt")
        let entities = try await ExportedTranscriptFileQuery().entities(for: [.file(url: url)])
        let entity = try #require(entities.first)
        #expect(entity.title == "Quarterly Review")
    }
}
