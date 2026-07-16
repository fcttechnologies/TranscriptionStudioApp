import AppIntents
import Foundation

/// Kick a link transcription — the "+ → Insert Link" prompt's intent form. URL ingest is
/// Mac-only (the yt-dlp/ffmpeg downloader `AppModel` only carries on macOS); on iOS this throws
/// a clean, spoken explanation instead of silently queuing a job that can only fail. Always
/// foreground, like `TranscribeFileIntent` — the pipeline runs in the app process.
public struct TranscribeLinkIntent: AppIntent {
    public static let title: LocalizedStringResource = "Transcribe a Link"
    public static let description = IntentDescription(
        "Transcribe a TikTok, YouTube, or media link with Transcription Studio. Mac only.")
    public static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Link", description: "A TikTok, YouTube, or media URL to download and transcribe.")
    public var url: String

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        guard await MainActor.run(body: { appModel.urlDownloader != nil }) else {
            throw TranscribeLinkIntentError.unavailableOnThisDevice
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLValidation.isTranscribableURL(trimmed) else {
            throw TranscribeLinkIntentError.invalidLink
        }
        let displayTitle = URLValidation.suggestedTitle(for: trimmed)
        await MainActor.run {
            appModel.returnHome()   // the job's progress lives in the feed's In Progress section
            appModel.startTranscription(title: displayTitle, source: .url(trimmed))
        }
        return .result(opensIntent: OpenAppIntent(), dialog: "Transcribing \(displayTitle).")
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
