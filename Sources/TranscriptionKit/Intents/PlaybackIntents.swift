import AppIntents
import SwiftData

/// Errors surfaced by the playback intents.
enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noAudioAvailable
    case notPlaying

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAudioAvailable: "That transcript has no archived audio to play."
        case .notPlaying: "Nothing is playing right now."
        }
    }
}

/// Play back a transcript's archived audio — the mini-player's play control, reachable from
/// Siri/Shortcuts. Defaults to the latest transcript, mirroring `AskTranscriptIntent`.
public struct PlayTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play Transcript"
    public static let description = IntentDescription(
        "Play a transcript's archived audio in Transcription Studio. Defaults to your latest transcript.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Transcript", description: "Which transcript to play. Defaults to your latest.")
    public var target: TranscriptSessionEntity?

    @Dependency private var appModel: AppModel

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        let id: UUID?
        if let target {
            id = UUID(uuidString: target.id)
        } else {
            id = TranscriptSessionStore.latestEntityAndText().flatMap { UUID(uuidString: $0.entity.id) }
        }
        guard let id else { throw TranscriptionIntentError.noTranscripts }

        let context = appModel.modelContext
        let predicate = #Predicate<TranscriptSession> { $0.id == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let session = try context.fetch(descriptor).first else {
            throw TranscriptionIntentError.noTranscripts
        }
        guard appModel.playback.prepare(session: session) else {
            throw PlaybackIntentError.noAudioAvailable
        }
        if !appModel.playback.isPlaying {
            if appModel.playback.currentTime > 0, appModel.playback.nowPlaying?.sessionID == session.id {
                appModel.playback.togglePlayPause()   // resume where it paused
            } else {
                appModel.playback.play(from: 0)
            }
        }
        appModel.openSession(id: session.id)
        return .result(opensIntent: OpenAppIntent(), dialog: "Playing \"\(session.title)\".")
    }
}

/// Pause the transcript that's currently playing — the mini-player's pause control.
public struct PausePlaybackIntent: AppIntent {
    public static let title: LocalizedStringResource = "Pause Playback"
    public static let description = IntentDescription("Pause a transcript's playback in Transcription Studio.")

    @Dependency private var appModel: AppModel

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard appModel.playback.isPlaying else { throw PlaybackIntentError.notPlaying }
        appModel.playback.togglePlayPause()
        return .result(dialog: "Playback paused.")
    }
}
