import Foundation
import WhisperKit

/// Extensions accepted from a dropped/picked media file — ported from the web app's
/// upload whitelist (`ALLOWED_UPLOAD_EXTENSIONS` in main.py) so a hostile or garbage
/// suffix is rejected before it ever reaches ffmpeg/CoreML decoding.
public enum SupportedMediaExtensions {
    public static let allowed: Set<String> = [
        "mp3", "wav", "m4a", "mp4", "ogg", "flac", "opus", "aac", "webm", "mov", "mkv",
    ]

    public static func isSupported(_ url: URL) -> Bool {
        allowed.contains(url.pathExtension.lowercased())
    }
}

public enum FileIngestError: LocalizedError, Sendable {
    case unsupportedExtension(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(ext):
            "\(ext.isEmpty ? "That file" : "\".\(ext)\" files") isn't a supported audio/video type."
        case let .loadFailed(message):
            "Couldn't read that file: \(message)"
        }
    }
}

/// Cross-platform file ingest: a dropped/picked media file → 16 kHz mono Float32 samples.
/// Reuses WhisperKit's own `AudioProcessor` (AVAudioFile-backed, already resamples to
/// the model's input format and streams large files in chunks) rather than re-deriving
/// AVFoundation conversion.
public enum FileIngestService {
    public static func loadSamples(from url: URL) throws -> [Float] {
        guard SupportedMediaExtensions.isSupported(url) else {
            throw FileIngestError.unsupportedExtension(url.pathExtension)
        }
        do {
            return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        } catch {
            throw FileIngestError.loadFailed(error.localizedDescription)
        }
    }
}
