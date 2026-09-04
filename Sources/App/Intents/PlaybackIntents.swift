import AppIntents
import FCTMetrics
import SwiftData

/// Errors surfaced by the playback intents.
enum PlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noAudioAvailable
    case notPlaying
    case nothingToSpeak
    case notSpeaking

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAudioAvailable: "That transcript has no archived audio to play."
        case .notPlaying: "Nothing is playing right now."
        case .nothingToSpeak: "That transcript has no text to speak."
        case .notSpeaking: "Nothing is being spoken right now."
        }
    }
}

/// Play back a transcript's archived audio — the mini-player's play control, reachable from
/// Siri/Shortcuts. Defaults to the latest transcript, mirroring `AskTranscriptIntent`.
struct PlayTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Transcript"
    static let description = IntentDescription(
        "Play a transcript's archived audio in Transcription Studio. Defaults to your latest transcript.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Transcript", description: "Which transcript to play. Defaults to your latest.")
    var target: TranscriptSessionEntity?

    @Dependency private var appModel: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        func run() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
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
            guard await appModel.playback.prepare(session: session) else {
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
        return try await Diag.intent(TranscriptionCrumb.playTranscriptIntent, run)
    }
}

/// Read a transcript aloud with the on-device synthesized voice — distinct from
/// `PlayTranscriptIntent`, which plays the session's *archived recording*: this speaks the
/// transcript's text, so it works for sessions with no archived audio at all. Defaults to
/// the latest transcript, mirroring the rest of the family. Foreground: the voice plays
/// from the app process, and the mini-player carries its transport.
struct SpeakTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Transcript"
    static let description = IntentDescription(
        "Read a transcript aloud with the on-device voice in Transcription Studio. Defaults to your latest transcript.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Transcript", description: "Which transcript to speak. Defaults to your latest.")
    var target: TranscriptSessionEntity?

    @Dependency private var appModel: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        func run() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
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
            guard let session = try context.fetch(descriptor).first,
                  // The entity read-path already withholds private sessions; belt-and-suspenders
                  // here because a locked transcript spoken aloud is the canonical privacy hole.
                  PrivacyGate.isEligibleForAssistant(isPrivate: session.isPrivate) else {
                throw TranscriptionIntentError.noTranscripts
            }
            guard !(session.segments ?? []).isEmpty else { throw PlaybackIntentError.nothingToSpeak }

            appModel.startReadAloud(session: session)
            appModel.openSession(id: session.id)
            return .result(opensIntent: OpenAppIntent(), dialog: "Speaking \"\(session.title)\".")
        }
        return try await Diag.intent(TranscriptionCrumb.speakTranscriptIntent, run)
    }
}

/// Stop the on-device voice — the symmetric exit for a reading Siri started.
struct StopSpeakingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Speaking"
    static let description = IntentDescription(
        "Stop Transcription Studio's on-device voice reading a transcript aloud.")

    @Dependency private var appModel: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        func run() async throws -> some IntentResult & ProvidesDialog {
            guard appModel.readAloud.isActive else { throw PlaybackIntentError.notSpeaking }
            appModel.readAloud.stop()
            return .result(dialog: "Stopped speaking.")
        }
        return try await Diag.intent(TranscriptionCrumb.stopSpeakingIntent, run)
    }
}

/// Pause the transcript that's currently playing — the mini-player's pause control.
struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Playback"
    static let description = IntentDescription("Pause a transcript's playback in Transcription Studio.")

    @Dependency private var appModel: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        func run() async throws -> some IntentResult & ProvidesDialog {
            guard appModel.playback.isPlaying else { throw PlaybackIntentError.notPlaying }
            appModel.playback.togglePlayPause()
            return .result(dialog: "Playback paused.")
        }
        return try await Diag.intent(TranscriptionCrumb.pausePlaybackIntent, run)
    }
}
