// `TranscriptExport.Format`'s per-case presentation (id/displayName/fileExtension) and the
// constructible parts of `TranscriptExportDocument`, the write-only `FileDocument` a
// `fileExporter` saves an export as. Pure, no filesystem I/O — `TranscriptExportTests.swift`
// covers the render(_:as:) string formats and `DocxExporterTests.swift` covers the DOCX byte
// output; this covers the format metadata + document wrapper those files didn't touch.
//
// `init(configuration:)` and `fileWrapper(configuration:)` take `FileDocumentReadConfiguration`/
// `FileDocumentWriteConfiguration`, which SwiftUI constructs internally and expose no public
// initializer — untestable outside a real `fileExporter`/`fileImporter` round trip.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranscriptionStudio

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
        #expect(TranscriptExport.Format.docx.fileExtension == "docx")
    }
}

@Suite("TranscriptExportDocument")
struct TranscriptExportDocumentTests {
    @Test func carriesTheDataAndFormatItWasInitializedWith() {
        let document = TranscriptExportDocument(data: Data("hello world".utf8), format: .markdown)
        #expect(document.data == Data("hello world".utf8))
        #expect(document.format == .markdown)
    }

    @Test func theTextConvenienceInitializerUTF8EncodesTheString() {
        let document = TranscriptExportDocument(text: "hello world", format: .plainText)
        #expect(document.data == Data("hello world".utf8))
    }

    @Test func isWriteOnly() {
        #expect(TranscriptExportDocument.readableContentTypes.isEmpty)
        #expect(TranscriptExportDocument.writableContentTypes.contains(.plainText))
        #expect(TranscriptExportDocument.writableContentTypes.contains(.text))
        // DOCX doesn't conform to `.text` (it's a composite package, not plain text), so its
        // own resolved type must be advertised explicitly or `fileExporter` would reject it.
        #expect(TranscriptExportDocument.writableContentTypes.contains(TranscriptExportDocument.contentType(for: .docx)))
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
