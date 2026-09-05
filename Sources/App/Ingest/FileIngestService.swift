import Foundation
import UniformTypeIdentifiers
import FCTSpeech

/// Extensions accepted from a dropped/picked media file — ported from the web app's
/// upload whitelist (`ALLOWED_UPLOAD_EXTENSIONS` in main.py) so a hostile or garbage
/// suffix is rejected before it ever reaches ffmpeg/CoreML decoding.
enum SupportedMediaExtensions {
    static let allowed: Set<String> = [
        "mp3", "wav", "m4a", "mp4", "ogg", "flac", "opus", "aac", "webm", "mov", "mkv",
    ]

    static func isSupported(_ url: URL) -> Bool {
        allowed.contains(url.pathExtension.lowercased())
    }

    /// The whitelist as `UTType`s for a `fileImporter`'s `allowedContentTypes`. The `.audio`
    /// / `.movie` supertypes cover the common cases; the per-extension types then let the
    /// less-standard containers (mkv/webm/ogg/opus/flac) through, which the supertypes miss.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.audio, .movie]
        types += allowed.compactMap { UTType(filenameExtension: $0) }
        return types
    }
}

enum FileIngestError: LocalizedError, Sendable {
    case unsupportedExtension(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(ext):
            "\(ext.isEmpty ? "That file" : "\".\(ext)\" files") isn't a supported audio/video type."
        case let .loadFailed(message):
            "Couldn't read that file: \(message)"
        }
    }
}

/// Cross-platform file ingest: a dropped/picked media file → 16 kHz mono Float32 samples,
/// through FCTSpeech's reader (AVAudioFile-backed, resampling to the engines' input format).
enum FileIngestService {
    static func loadSamples(from url: URL) throws -> [Float] {
        guard SupportedMediaExtensions.isSupported(url) else {
            throw FileIngestError.unsupportedExtension(url.pathExtension)
        }
        do {
            return try AudioFileReader.monoFloat16k(url)
        } catch {
            throw FileIngestError.loadFailed(error.localizedDescription)
        }
    }
}
