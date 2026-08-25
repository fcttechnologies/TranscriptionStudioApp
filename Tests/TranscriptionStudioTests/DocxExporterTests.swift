// `DocxExporter` renders a transcript as a minimal OOXML `.docx` package. These tests prove the
// bytes it produces are an actually-valid zip (via `ZipReader`, a from-scratch reader of the
// same stored-only format `MinimalZip` writes — parsing the central directory, extracting each
// entry's raw bytes, and recomputing its CRC-32 to confirm it matches the header) whose four
// parts are all well-formed XML (`XMLParser`), and that the rendered content carries the title,
// speaker labels, and transcript text — the practical stand-in for "opens in Word/Pages" a unit
// test can assert without shelling out or launching either app.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("DocxExporter")
struct DocxExporterTests {
    private let items = [
        TranscriptExport.Item(speaker: "Me", start: 0, end: 3.2, text: "Good morning everyone."),
        TranscriptExport.Item(speaker: "Speaker 2", start: 3.2, end: 7.85, text: "Happy to be here."),
        TranscriptExport.Item(speaker: "Speaker 2", start: 7.85, end: 12, text: "I reviewed the proposal."),
    ]

    @Test func producesAZipWithExactlyTheFourRequiredParts() throws {
        let data = DocxExporter.build(items, title: "Standup")
        let entries = try ZipReader.entries(in: data)
        let names = Set(entries.map(\.name))
        #expect(names == ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/_rels/document.xml.rels"])
    }

    @Test func everyEntrysCRCMatchesItsData() throws {
        // ZipReader recomputes and checks each entry's CRC-32 against its local header while
        // extracting and throws on a mismatch — a successful, non-throwing `entries(in:)` call
        // (the test function itself is `throws`, so a thrown error fails it) already proves
        // this; this test names the property explicitly.
        let data = DocxExporter.build(items, title: "Standup")
        _ = try ZipReader.entries(in: data)
    }

    @Test func everyPartIsWellFormedXML() throws {
        let data = DocxExporter.build(items, title: "Standup")
        for entry in try ZipReader.entries(in: data) {
            let parser = XMLParser(data: entry.data)
            #expect(parser.parse(), "\(entry.name) failed to parse: \(String(describing: parser.parserError))")
        }
    }

    @Test func documentBodyCarriesTitleSpeakersAndText() throws {
        let data = DocxExporter.build(items, title: "Standup")
        let document = try #require(ZipReader.entries(in: data).first { $0.name == "word/document.xml" })
        let xml = String(decoding: document.data, as: UTF8.self)
        #expect(xml.contains("Standup"))
        #expect(xml.contains("Me"))
        #expect(xml.contains("Speaker 2"))
        #expect(xml.contains("Good morning everyone."))
        #expect(xml.contains("Happy to be here."))
        #expect(xml.contains("I reviewed the proposal."))
    }

    @Test func consecutiveSameSpeakerLinesShareOneHeader() throws {
        // Speaker 2 has two consecutive items — only one "Speaker 2" header paragraph, not two,
        // mirroring TranscriptExport.markdown's grouping.
        let data = DocxExporter.build(items, title: "")
        let document = try #require(ZipReader.entries(in: data).first { $0.name == "word/document.xml" })
        let xml = String(decoding: document.data, as: UTF8.self)
        #expect(xml.components(separatedBy: ">Speaker 2<").count == 2)   // one occurrence
    }

    @Test func omitsTheTitleParagraphWhenTitleIsEmpty() throws {
        let data = DocxExporter.build(items, title: "")
        let document = try #require(ZipReader.entries(in: data).first { $0.name == "word/document.xml" })
        let xml = String(decoding: document.data, as: UTF8.self)
        #expect(!xml.contains("w:sz w:val=\"32\""))
    }

    @Test func escapesXMLSpecialCharactersInSpeakerAndText() throws {
        let unsafe = [
            TranscriptExport.Item(speaker: "A & B", start: 0, end: 1,
                                  text: "<tag> \"quoted\" & 'more' text"),
        ]
        let data = DocxExporter.build(unsafe, title: "R&D <notes>")
        let entries = try ZipReader.entries(in: data)   // throws if the zip itself is malformed
        let document = try #require(entries.first { $0.name == "word/document.xml" })
        // A well-formed parse is only possible if the raw &, <, >, ", ' in the source text and
        // title were escaped — any of them left raw would break the XML.
        let parser = XMLParser(data: document.data)
        #expect(parser.parse(), "failed to parse: \(String(describing: parser.parserError))")
        let xml = String(decoding: document.data, as: UTF8.self)
        #expect(xml.contains("A &amp; B"))
        #expect(xml.contains("&lt;tag&gt; &quot;quoted&quot; &amp; &apos;more&apos; text"))
        #expect(xml.contains("R&amp;D &lt;notes&gt;"))
    }

    @Test func handlesEmptyTranscript() throws {
        let data = DocxExporter.build([], title: "Empty")
        let entries = try ZipReader.entries(in: data)
        #expect(entries.count == 4)
        for entry in entries {
            #expect(XMLParser(data: entry.data).parse())
        }
    }

    @Test func isDeterministicForIdenticalInput() {
        // MinimalZip stamps a fixed DOS timestamp precisely so this holds — a real build tool
        // must produce byte-identical output for identical input.
        let first = DocxExporter.build(items, title: "Standup")
        let second = DocxExporter.build(items, title: "Standup")
        #expect(first == second)
    }
}

/// A from-scratch reader of the stored-only ZIP subset `MinimalZip` writes: walks the central
/// directory, then extracts each entry's raw (uncompressed) bytes and recomputes its CRC-32,
/// throwing on any mismatch or malformed record. Deliberately independent of `MinimalZip`'s own
/// code, so it can't share a bug with the writer it's verifying.
private enum ZipReader {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ReaderError: Error {
        case noEndOfCentralDirectory
        case badSignature
        case crcMismatch(String)
        case unsupportedCompression(String)
    }

    static func entries(in archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard let eocdStart = findEndOfCentralDirectory(bytes) else { throw ReaderError.noEndOfCentralDirectory }

        let recordCount = Int(le16(bytes, eocdStart + 10))
        let centralDirectoryOffset = Int(le32(bytes, eocdStart + 16))

        var results: [Entry] = []
        var cursor = centralDirectoryOffset
        for _ in 0..<recordCount {
            guard le32(bytes, cursor) == 0x0201_4b50 else { throw ReaderError.badSignature }
            let crc = le32(bytes, cursor + 16)
            let compressedSize = Int(le32(bytes, cursor + 20))
            let nameLength = Int(le16(bytes, cursor + 28))
            let extraLength = Int(le16(bytes, cursor + 30))
            let commentLength = Int(le16(bytes, cursor + 32))
            let method = le16(bytes, cursor + 10)
            let localHeaderOffset = Int(le32(bytes, cursor + 42))
            let nameStart = cursor + 46
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            guard method == 0 else { throw ReaderError.unsupportedCompression(name) }   // MinimalZip only stores

            let localNameLength = Int(le16(bytes, localHeaderOffset + 26))
            let localExtraLength = Int(le16(bytes, localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
            let entryData = Data(bytes[dataStart..<(dataStart + compressedSize)])

            guard crc32(entryData) == crc else { throw ReaderError.crcMismatch(name) }
            results.append(Entry(name: name, data: entryData))

            cursor += 46 + nameLength + extraLength + commentLength
        }
        return results
    }

    /// Scans backward for the end-of-central-directory signature — it can trail a short comment,
    /// so it isn't necessarily the archive's last 22 bytes.
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        while index >= 0 {
            if le32(bytes, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
