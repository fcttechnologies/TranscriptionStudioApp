import AppIntents
import Foundation

/// Kick a link transcription and follow it to completion — the "+ → Insert Link" prompt's intent
/// form. URL ingest is Mac-only (the yt-dlp/ffmpeg downloader `AppModel` only carries on macOS);
/// on iOS this throws a clean, spoken explanation instead of silently queuing a job that can only
/// fail. A `LongRunningIntent` + `CancellableIntent` for the same reasons as `TranscribeFileIntent`
/// (download + heavy on-device inference is long-running work), sharing its `completeTranscription`
/// body: progress to Siri/Shortcuts, extended runtime if backgrounded, and cancel wired to
/// `TranscriptionJob.cancel()`. Always foreground — the pipeline runs in the app process.
public struct TranscribeLinkIntent: LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Transcribe a Link"
    public static let description = IntentDescription(
        "Transcribe a TikTok, YouTube, or media link with Transcription Studio. Mac only.")
    public static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Link", description: "A TikTok, YouTube, or media URL to download and transcribe.")
    public var url: String

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<TranscriptSessionEntity> & ProvidesDialog {
        guard await MainActor.run(body: { appModel.urlDownloader != nil }) else {
            throw TranscribeLinkIntentError.unavailableOnThisDevice
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLValidation.isTranscribableURL(trimmed) else {
            throw TranscribeLinkIntentError.invalidLink
        }
        let displayTitle = URLValidation.suggestedTitle(for: trimmed)
        let job = await MainActor.run { () -> TranscriptionJob in
            appModel.returnHome()   // the job's progress lives in the feed's In Progress section
            return appModel.startTranscription(title: displayTitle, source: .url(trimmed))
        }
        return try await completeTranscription(job: job, displayTitle: displayTitle, appModel: appModel)
    }
}

enum TranscribeLinkIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailableOnThisDevice
    case invalidLink

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailableOnThisDevice: "Link transcription isn't available on this device."
        case .invalidLink: "That doesn't look like a valid link."
        }
    }
}
