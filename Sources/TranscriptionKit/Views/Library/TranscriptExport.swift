import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Pure transcript export formatting: a saved session's segments → shareable text in the
/// standard interchange formats. No I/O here — callers hand the string to a share sheet,
/// the pasteboard, or a file writer.
public enum TranscriptExport {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case plainText
        case markdown
        case srt
        case vtt

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .plainText: String(localized: "Plain text")
            case .markdown: String(localized: "Markdown")
            case .srt: String(localized: "SubRip (.srt)")
            case .vtt: String(localized: "WebVTT (.vtt)")
            }
        }

        public var fileExtension: String {
            switch self {
            case .plainText: "txt"
            case .markdown: "md"
            case .srt: "srt"
            case .vtt: "vtt"
            }
        }
    }

    /// One exportable line, independent of the storage type so it's trivially testable.
    public struct Item: Sendable {
        public let speaker: String?
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String

        public init(speaker: String?, start: TimeInterval, end: TimeInterval, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// Map a session's stored segments to export items (time-sorted; speaker names shown
    /// only when the session actually has attribution — a plain file transcription with
    /// every segment unknown exports as clean unprefixed text).
    public static func items(from session: TranscriptSession) -> [Item] {
        let sorted = (session.segments ?? []).sorted { $0.start < $1.start }
        let hasAttribution = sorted.contains { $0.speaker != .unknown }
        return sorted.map { segment in
            Item(speaker: hasAttribution ? segment.speaker.displayName : nil,
                 start: segment.start,
                 end: segment.end,
                 text: segment.text)
        }
    }

    public static func render(_ items: [Item], as format: Format, title: String = "") -> String {
        switch format {
        case .plainText: plainText(items)
        case .markdown: markdown(items, title: title)
        case .srt: srt(items)
        case .vtt: vtt(items)
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

/// The write-only document a `fileExporter` saves an export as. Content is rendered before
/// the exporter presents, so the document is just a string with a content type.
public struct TranscriptExportDocument: FileDocument {
    public static let readableContentTypes: [UTType] = []
    public static let writableContentTypes: [UTType] = [.plainText, .text]

    public let text: String
    public let format: TranscriptExport.Format

    public init(text: String, format: TranscriptExport.Format) {
        self.text = text
        self.format = format
    }

    /// Best-available UTType for a format (falls back to plain text when the system has no
    /// registered type for the extension).
    public static func contentType(for format: TranscriptExport.Format) -> UTType {
        UTType(filenameExtension: format.fileExtension) ?? .plainText
    }

    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)   // export-only
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
