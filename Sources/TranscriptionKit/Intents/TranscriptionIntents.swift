import Foundation
import AppIntents
import UniformTypeIdentifiers

// App Intents exposing Transcription Studio to Siri, Shortcuts, and Apple Intelligence.
// Each intent is a thin adapter over the app's existing model/use-cases — no business logic
// lives here. Intents that drive live capture or navigation open the app; read-only intents
// (search, latest, ask) run in the background against the shared store.

/// Errors surfaced to Siri/Shortcuts as spoken/displayed dialog.
enum TranscriptionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRecording
    case noTranscripts

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRecording: "Nothing is recording right now."
        case .noTranscripts: "You don't have any transcripts yet."
        }
    }
}

// MARK: - Recording

/// Start a room recording. Opens the app — live capture needs the foreground process.
public struct StartRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Recording"
    public static let description = IntentDescription(
        "Start a new room recording and live transcription in Transcription Studio.")
    public static let openAppWhenRun = true

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            appModel.selectedSurface = .record
            if !appModel.recording.isRecording { appModel.recording.start(mode: .room) }
        }
        return .result(dialog: "Recording started.")
    }
}

/// Stop the current recording, returning the saved session and a short snippet.
public struct StopRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop Recording"
    public static let description = IntentDescription(
        "Stop the current recording in Transcription Studio and save the transcript.")

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<TranscriptSessionEntity> & ProvidesDialog {
        let recording = await MainActor.run { appModel.recording }
        guard await recording.isRecording else { throw TranscriptionIntentError.notRecording }
        let id = await recording.stop()
        guard let id, let saved = await TranscriptSessionStore.entityAndText(forID: id) else {
            throw TranscriptionIntentError.notRecording
        }
        let snippet = String(saved.fullText.prefix(240))
        let dialog: IntentDialog = snippet.isEmpty
            ? "Recording saved."
            : "Recording saved. \(snippet)"
        return .result(value: saved.entity, dialog: dialog)
    }
}

// MARK: - Transcribe a file

/// Kick a file transcription. Opens the app so the job runs in the live process and its
/// progress is visible on the Transcribe surface.
public struct TranscribeFileIntent: AppIntent {
    public static let title: LocalizedStringResource = "Transcribe a File"
    public static let description = IntentDescription(
        "Transcribe an audio or video file with Transcription Studio.")
    public static let openAppWhenRun = true

    @Parameter(title: "File", description: "The audio or video file to transcribe.",
               supportedContentTypes: [.audio, .movie])
    public var file: IntentFile

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = file.filename
        let title = (name as NSString).deletingPathExtension
        let displayTitle = title.isEmpty ? "Audio file" : title
        await MainActor.run {
            appModel.selectedSurface = .transcribe
            appModel.startTranscription(title: displayTitle,
                                        source: .file(name: name, durationHint: 30))
        }
        return .result(dialog: "Transcribing \(displayTitle).")
    }
}

// MARK: - Search

/// Search saved transcripts by title and content. Runs in the background and returns the
/// matches; if asked, brings the app to the Library.
public struct SearchTranscriptsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search Transcripts"
    public static let description = IntentDescription(
        "Search your saved transcripts by title or spoken content.")

    @Parameter(title: "Search text", description: "What to look for in your transcripts.")
    public var query: String

    @Parameter(title: "Open in Library", description: "Also open the Library to browse results.",
               default: false)
    public var openLibrary: Bool

    @Dependency private var appModel: AppModel

    public var supportedModes: IntentModes { .foreground(.dynamic) }

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<[TranscriptSessionEntity]> & ProvidesDialog {
        let results = await TranscriptSessionStore.entities(matching: query)
        if openLibrary {
            try await continueInForeground(alwaysConfirm: false)
            await MainActor.run { appModel.selectedSurface = .library }
        }
        let dialog: IntentDialog = results.isEmpty
            ? "No transcripts match “\(query)”."
            : "Found \(results.count) transcript\(results.count == 1 ? "" : "s")."
        return .result(value: results, dialog: dialog)
    }
}

// MARK: - Latest transcript

/// Return the newest transcript's full text — "read me my last transcript".
public struct GetLatestTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Latest Transcript"
    public static let description = IntentDescription(
        "Read back the full text of your most recent transcript.")

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let latest = await TranscriptSessionStore.latestEntityAndText() else {
            throw TranscriptionIntentError.noTranscripts
        }
        let text = latest.fullText
        let dialog: IntentDialog = text.isEmpty ? "Your latest transcript is empty." : "\(text)"
        return .result(value: text, dialog: dialog)
    }
}

// MARK: - Ask (Foundation Models Q&A)

/// Ask a question about a transcript, answered on-device by Apple Intelligence. Defaults to
/// the latest recording, so "ask my last recording what they said about the budget" works.
/// Degrades gracefully to a spoken explanation when Apple Intelligence isn't available.
public struct AskTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask a Transcript"
    public static let description = IntentDescription(
        "Ask a question about a transcript. Apple Intelligence answers on-device from the transcript.")

    @Parameter(title: "Question", description: "What you want to know about the transcript.")
    public var question: String

    @Parameter(title: "Transcript", description: "Which transcript to ask about. Defaults to your latest.")
    public var session: TranscriptSessionEntity?

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let target: (entity: TranscriptSessionEntity, fullText: String)?
        if let session, let id = UUID(uuidString: session.id) {
            target = await TranscriptSessionStore.entityAndText(forID: id)
        } else {
            target = await TranscriptSessionStore.latestEntityAndText()
        }
        guard let target else { throw TranscriptionIntentError.noTranscripts }

        let intelligence = SessionIntelligence()
        guard intelligence.status.isAvailable else {
            return .result(value: "", dialog: "\(intelligence.status.message)")
        }
        do {
            let answer = try await intelligence.answer(question: question, transcript: target.fullText)
            return .result(value: answer, dialog: "\(answer)")
        } catch {
            return .result(value: "", dialog: "\(SessionIntelligence.errorMessage(for: error))")
        }
    }
}

// MARK: - Open

/// Open a transcript in the app — also powers tapping a Spotlight result.
public struct OpenTranscriptIntent: AppIntent, OpenIntent {
    public static let title: LocalizedStringResource = "Open Transcript"
    public static let description = IntentDescription("Open a transcript in Transcription Studio.")
    public static let openAppWhenRun = true

    @Parameter(title: "Transcript")
    public var target: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult {
        let id = UUID(uuidString: target.id)
        await MainActor.run {
            if let id { appModel.selectedSessionID = id }
            appModel.selectedSurface = .library
        }
        return .result()
    }
}

// MARK: - App Shortcuts

/// Zero-setup Siri phrases. `\(.applicationName)` binds each phrase to the app.
public struct TranscriptionShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Start a new recording in \(.applicationName)",
                "New recording in \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic")

        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording in \(.applicationName)",
                "Stop my \(.applicationName) recording"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle")

        AppShortcut(
            intent: TranscribeFileIntent(),
            phrases: [
                "Transcribe a file with \(.applicationName)",
                "Transcribe a file in \(.applicationName)"
            ],
            shortTitle: "Transcribe File",
            systemImageName: "waveform")

        AppShortcut(
            intent: SearchTranscriptsIntent(),
            phrases: [
                "Search my transcripts in \(.applicationName)",
                "Search \(.applicationName) transcripts"
            ],
            shortTitle: "Search Transcripts",
            systemImageName: "magnifyingglass")

        AppShortcut(
            intent: GetLatestTranscriptIntent(),
            phrases: [
                "Read my last transcript in \(.applicationName)",
                "What's my latest \(.applicationName) transcript"
            ],
            shortTitle: "Latest Transcript",
            systemImageName: "text.quote")

        AppShortcut(
            intent: AskTranscriptIntent(),
            phrases: [
                "Ask my last recording in \(.applicationName)",
                "Ask \(.applicationName) about my transcript"
            ],
            shortTitle: "Ask a Transcript",
            systemImageName: "questionmark.bubble")

        AppShortcut(
            intent: OpenTranscriptIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)"
            ],
            shortTitle: "Open Transcript",
            systemImageName: "doc.text")
    }
}

// MARK: - Dependency registration

/// Register the live `AppModel` so intents can resolve it via `@Dependency`. Called from each
/// app shell's `init` (both platforms) so the dependency is ready whenever the app process
/// runs an intent.
public enum TranscriptionAppIntents {
    @MainActor
    public static func registerDependencies(appModel: AppModel) {
        AppDependencyManager.shared.add(dependency: appModel)
    }
}
