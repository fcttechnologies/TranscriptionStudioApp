// `TranscriptExport.Format`'s per-case presentation (id/displayName/fileExtension) and the
// constructible parts of `TranscriptExportDocument`, the write-only `FileDocument` a
// `fileExporter` saves an export as. Pure, no filesystem I/O — `TranscriptExportTests.swift`
// covers the render(_:as:) string formats; this covers the format metadata + document wrapper
// that file didn't touch.
//
// `init(configuration:)` and `fileWrapper(configuration:)` take `FileDocumentReadConfiguration`/
// `FileDocumentWriteConfiguration`, which SwiftUI constructs internally and expose no public
// initializer — untestable outside a real `fileExporter`/`fileImporter` round trip.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranscriptionKit

@Suite("TranscriptExport.Format — metadata")
struct TranscriptExportFormatMetadataTests {
    @Test func idMatchesTheRawValue() {
        for format in TranscriptExport.Format.allCases {
            #expect(format.id == format.rawValue)
        }
    }

    @Test func everyFormatHasADistinctNonEmptyDisplayName() {
        let names = TranscriptExport.Format.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test func fileExtensionsMatchTheStandardInterchangeSuffixes() {
        #expect(TranscriptExport.Format.plainText.fileExtension == "txt")
        #expect(TranscriptExport.Format.markdown.fileExtension == "md")
        #expect(TranscriptExport.Format.srt.fileExtension == "srt")
        #expect(TranscriptExport.Format.vtt.fileExtension == "vtt")
    }
}

@Suite("TranscriptExportDocument")
struct TranscriptExportDocumentTests {
    @Test func carriesTheTextAndFormatItWasInitializedWith() {
        let document = TranscriptExportDocument(text: "hello world", format: .markdown)
        #expect(document.text == "hello world")
        #expect(document.format == .markdown)
    }

    @Test func isWriteOnly() {
        #expect(TranscriptExportDocument.readableContentTypes.isEmpty)
        #expect(TranscriptExportDocument.writableContentTypes == [.plainText, .text])
    }

    @Test func contentTypeMatchesTheFormatsExtensionWhenRegistered() {
        #expect(TranscriptExportDocument.contentType(for: .plainText) == .plainText)
    }

    @Test func contentTypeNeverReturnsNilForAnyFormat() {
        // Every format resolves to SOME UTType (falling back to .plainText when the system
        // has no registered type for the extension) — never a crash on an unrecognized one.
        for format in TranscriptExport.Format.allCases {
            let type = TranscriptExportDocument.contentType(for: format)
            #expect(type == UTType(filenameExtension: format.fileExtension) || type == .plainText)
        }
    }
}
