import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Pure transcript export formatting: a saved session's segments → shareable text in the
/// standard interchange formats. No I/O here — callers hand the string to a share sheet,
/// the pasteboard, or a file writer.
enum TranscriptExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case plainText
        case markdown
        case srt
        case vtt
        case docx

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plainText: String(localized: "Plain text")
            case .markdown: String(localized: "Markdown")
            case .srt: String(localized: "SubRip (.srt)")
            case .vtt: String(localized: "WebVTT (.vtt)")
            case .docx: String(localized: "Word (.docx)")
            }
        }

        var fileExtension: String {
            switch self {
            case .plainText: "txt"
            case .markdown: "md"
            case .srt: "srt"
            case .vtt: "vtt"
            case .docx: "docx"
            }
        }
    }

    /// One exportable line, independent of the storage type so it's trivially testable.
    struct Item: Sendable {
        let speaker: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String

        init(speaker: String?, start: TimeInterval, end: TimeInterval, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Map a session's stored segments to export items (time-sorted; speaker names shown
    /// only when the session actually has attribution — a plain file transcription with
    /// every segment unknown exports as clean unprefixed text).
    static func items(from session: TranscriptSession) -> [Item] {
        let sorted = (session.segments ?? []).sorted { $0.start < $1.start }
        let hasAttribution = sorted.contains { $0.speaker != .unknown }
        return sorted.map { segment in
            Item(speaker: hasAttribution ? segment.speaker.displayName : nil,
                 start: segment.start,
                 end: segment.end,
                 text: segment.text)
        }
    }

    /// Renders a text-based format as a string. DOCX has no meaningful string form (it's a
    /// binary zip package) — call `renderData(_:as:title:)` instead, which handles every format
    /// including it.
    static func render(_ items: [Item], as format: Format, title: String = "") -> String {
        switch format {
        case .plainText: plainText(items)
        case .markdown: markdown(items, title: title)
        case .srt: srt(items)
        case .vtt: vtt(items)
        case .docx: preconditionFailure("DOCX is binary — use renderData(_:as:title:) instead.")
        }
    }

    /// The canonical byte-level render, and the one entry point every export surface (the
    /// `fileExporter`, `ExportTranscriptIntent`, Shortcuts) should call: text formats UTF-8
    /// encode `render(_:as:title:)`'s string, DOCX renders as a real OOXML package.
    static func renderData(_ items: [Item], as format: Format, title: String = "") -> Data {
        switch format {
        case .docx: DocxExporter.build(items, title: title)
        case .plainText, .markdown, .srt, .vtt: Data(render(items, as: format, title: title).utf8)
        }
    }

    // MARK: - Formats

    static func plainText(_ items: [Item]) -> String {
        items.map { item in
            item.speaker.map { "\($0): \(item.text)" } ?? item.text
        }
        .joined(separator: "\n")
    }

    static func markdown(_ items: [Item], title: String) -> String {
        var lines: [String] = []
        if !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }
        var lastSpeaker: String??
        for item in items {
            if item.speaker != lastSpeaker {
                if lastSpeaker != nil { lines.append("") }
                if let speaker = item.speaker {
                    lines.append("**\(speaker)** · \(clock(item.start))")
                }
                lastSpeaker = item.speaker
            }
            lines.append(item.text)
        }
        return lines.joined(separator: "\n")
    }

    static func srt(_ items: [Item]) -> String {
        items.enumerated().map { index, item in
            let text = item.speaker.map { "\($0): \(item.text)" } ?? item.text
            return "\(index + 1)\n\(srtTime(item.start)) --> \(srtTime(item.end))\n\(text)"
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ items: [Item]) -> String {
        let cues = items.map { item in
            let voiced = item.speaker.map { "<v \($0)>\(item.text)" } ?? item.text
            return "\(vttTime(item.start)) --> \(vttTime(item.end))\n\(voiced)"
        }
        .joined(separator: "\n\n")
        return "WEBVTT\n\n" + cues + "\n"
    }

    // MARK: - Time formatting

    /// `HH:MM:SS,mmm` (SRT uses a comma for milliseconds).
    static func srtTime(_ seconds: TimeInterval) -> String {
        timestamp(seconds, separator: ",")
    }

    /// `HH:MM:SS.mmm` (WebVTT uses a period).
    static func vttTime(_ seconds: TimeInterval) -> String {
        timestamp(seconds, separator: ".")
    }

    private static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let clamped = max(seconds, 0)
        let totalMillis = Int((clamped * 1000).rounded())
        let h = totalMillis / 3_600_000
        let m = (totalMillis % 3_600_000) / 60_000
        let s = (totalMillis % 60_000) / 1000
        let ms = totalMillis % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        TimeFormat.clock(seconds)
    }
}

/// The write-only document a `fileExporter` saves an export as. Content is rendered (via
/// `TranscriptExport.renderData`) before the exporter presents, so the document is just bytes
/// with a content type — a text format's UTF-8 string or DOCX's binary OOXML package.
struct TranscriptExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    /// `.text` covers every textual format (plain/markdown/srt/vtt all conform to it) without
    /// hardcoding each one's concrete UTI; DOCX doesn't conform to `.text` (it's a composite
    /// package), so its own resolved type is added explicitly.
    static let writableContentTypes: [UTType] = [.plainText, .text, contentType(for: .docx)]

    let data: Data
    let format: TranscriptExport.Format

    init(data: Data, format: TranscriptExport.Format) {
        self.data = data
        self.format = format
    }

    /// Convenience for the text formats — UTF-8 encodes the string.
    init(text: String, format: TranscriptExport.Format) {
        self.init(data: Data(text.utf8), format: format)
    }

    /// Best-available UTType for a format (falls back to plain text when the system has no
    /// registered type for the extension).
    static func contentType(for format: TranscriptExport.Format) -> UTType {
        UTType(filenameExtension: format.fileExtension) ?? .plainText
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)   // export-only
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
