import Foundation

/// One progress tick from a URL audio download.
struct DownloadProgress: Sendable {
    let fractionCompleted: Double?
    let etaText: String?

    init(fractionCompleted: Double?, etaText: String?) {
        self.fractionCompleted = fractionCompleted
        self.etaText = etaText
    }
}

enum URLIngestError: LocalizedError, Sendable {
    case toolNotFound(String)
    case downloadFailed(String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case let .toolNotFound(tool):
            "\(tool) isn't installed. Install it with Homebrew (`brew install \(tool)`) and try again."
        case let .downloadFailed(message):
            "Download failed: \(message)"
        case .outputMissing:
            "Download finished but the audio file wasn't found."
        }
    }
}

/// Downloads and extracts the audio for a URL transcription job. URL transcription is
/// Mac-only (yt-dlp/ffmpeg don't run on iOS), but `TranscriptionService`'s orchestration
/// is shared — it depends only on this seam, so the Mac-only `URLIngestService`
/// (yt-dlp + ffmpeg subprocess) is the sole conformer and the shared code never needs to
/// import `TranscriptionMacKit`.
protocol URLAudioDownloading: Sendable {
    /// Downloads `url`'s audio and extracts it to a local file, isolated under `jobID`.
    func downloadAudio(url: String, jobID: UUID,
                       onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
    /// Removes the job's temp files once its audio has been ingested.
    func cleanup(jobID: UUID) async
}
