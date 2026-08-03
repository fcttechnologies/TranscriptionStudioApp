import Foundation
import AppIntents
import UniformTypeIdentifiers

// App Intents exposing Transcription Studio to Siri, Shortcuts, and Apple Intelligence.
// Each intent is a thin adapter over the app's existing model/use-cases — no business logic
// lives here. Intents that drive live capture or navigation set the router state, then hand
// control back to the app via `.result(opensIntent: OpenAppIntent())` (see `OpenAppIntent.swift`);
// the long-running transcribe intents (file/link) open the app and then *follow* their
// `TranscriptionJob` to completion — reporting progress and honoring cancellation
// (`LongRunningIntent`/`CancellableIntent`); read-only intents (search, latest, ask, summarize,
// export, status) run in the background against the shared store.

/// Errors surfaced to Siri/Shortcuts as spoken/displayed dialog.
enum TranscriptionIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRecording
    case noTranscripts
    case alreadyRecording

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRecording: "Nothing is recording right now."
        case .noTranscripts: "You don't have any transcripts yet."
        case .alreadyRecording: "A recording is already in progress."
        }
    }
}

// MARK: - Recording

/// Siri-facing recording mode. A dedicated `AppEnum` (not `RecordingController.Mode` itself)
/// so the domain type carries no App Intents conformance. Meeting capture needs macOS
/// (ScreenCaptureKit system audio); the `meeting` case only exists in the macOS build, so
/// Siri/Shortcuts on iPhone/iPad never offers it as a choice — enforced at compile time
/// rather than a runtime guard.
#if os(macOS)
public enum RecordingModeAppEnum: String, AppEnum {
    case room
    case meeting

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Recording Mode")
    }

    public static var caseDisplayRepresentations: [RecordingModeAppEnum: DisplayRepresentation] {
        [.room: "Room", .meeting: "Meeting"]
    }

    var controllerMode: RecordingController.Mode {
        switch self {
        case .room: .room
        case .meeting: .meeting
        }
    }
}
#else
public enum RecordingModeAppEnum: String, AppEnum {
    case room

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Recording Mode")
    }

    public static var caseDisplayRepresentations: [RecordingModeAppEnum: DisplayRepresentation] {
        [.room: "Room"]
    }

    var controllerMode: RecordingController.Mode { .room }
}
#endif

/// Start a recording. Opens the app — live capture needs the foreground process. Guards
/// against a redundant start *before* touching the recorder, so a second "start recording"
/// while one is already running throws rather than silently no-opping behind a false
/// "Recording started." dialog.
public struct StartRecordingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Recording"
    public static let description = IntentDescription(
        "Start a new room or meeting recording and live transcription in Transcription Studio.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Mode", description: "Room (your mic) or Meeting (system audio + mic, Mac only).",
               default: .room)
    public var mode: RecordingModeAppEnum

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        try await MainActor.run {
            guard !appModel.recording.isRecording else { throw TranscriptionIntentError.alreadyRecording }
            appModel.playback.unload()
            appModel.readAloud.stop()
            appModel.recording.start(mode: mode.controllerMode)
            appModel.activeSheet = .liveRecording
        }
        return .result(opensIntent: OpenAppIntent(), dialog: "Recording started.")
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

/// Check whether Transcription Studio is currently recording — "am I recording?".
public struct GetRecordingStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Recording Status"
    public static let description = IntentDescription(
        "Check whether Transcription Studio is currently recording.")

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let recording = await MainActor.run { appModel.recording }
        let isRecording = await recording.isRecording
        let dialog: IntentDialog
        if isRecording {
            let elapsed = await recording.elapsed
            dialog = "Recording — \(TimeFormat.clock(elapsed)) elapsed."
        } else {
            dialog = "Not recording."
        }
        return .result(value: isRecording, dialog: dialog)
    }
}

// MARK: - Transcribe a file

/// Kick a file transcription and follow it to completion. A file transcription is the canonical
/// long-running-intent case (heavy on-device ML inference that can take minutes), so this is a
/// `LongRunningIntent` + `CancellableIntent`: it opens the app so the job runs in the live
/// process with its progress visible on the Transcribe surface, reports that progress to
/// Siri/Shortcuts/Live Activities, and — via `performBackgroundTask` — keeps the pipeline alive
/// with extended runtime if the user backgrounds the app mid-job. A cancel from any of those
/// surfaces flows to the existing `TranscriptionJob.cancel()`, the real cancellation path.
/// Always foreground — the pipeline runs in the app process, so (unlike
/// `StartRecordingIntent`/`OpenTranscriptIntent`) there's no dynamic "may not need it" case.
public struct TranscribeFileIntent: LongRunningIntent, CancellableIntent {
    public static let title: LocalizedStringResource = "Transcribe a File"
    public static let description = IntentDescription(
        "Transcribe an audio or video file with Transcription Studio.")
    public static let supportedModes: IntentModes = .foreground

    @Parameter(title: "File", description: "The audio or video file to transcribe.",
               supportedContentTypes: [.audio, .movie])
    public var file: IntentFile

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<TranscriptSessionEntity> & ProvidesDialog {
        let name = file.filename
        let title = (name as NSString).deletingPathExtension
        let displayTitle = title.isEmpty ? "Audio file" : title
        // The real pipeline ingests from a URL. Use the provided file URL when the intent
        // carries one; otherwise materialize the bytes into a temp file the ingest can read.
        let url: URL
        if let fileURL = file.fileURL {
            url = fileURL
        } else {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("IntentImports", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try file.data.write(to: dest)
            url = dest
        }
        let job = await MainActor.run { () -> TranscriptionJob in
            appModel.returnHome()   // the job's progress lives in the feed's In Progress section
            return appModel.startTranscription(title: displayTitle, source: .file(url))
        }
        return try await completeTranscription(job: job, displayTitle: displayTitle, appModel: appModel)
    }
}

extension LongRunningIntent where Self: CancellableIntent {
    /// Shared long-running body for the transcribe intents: extend the runtime via
    /// `performBackgroundTask`, mirror the job's progress into the intent's system `Progress`,
    /// route a system cancellation to `TranscriptionJob.cancel()`, then open and return the
    /// produced session. Lives on the protocol so `TranscribeFileIntent` and `TranscribeLinkIntent`
    /// share one implementation.
    func completeTranscription(job: TranscriptionJob, displayTitle: String,
                               appModel: AppModel) async throws
        -> some IntentResult & ReturnsValue<TranscriptSessionEntity> & ProvidesDialog {
        let sessionID = try await performBackgroundTask {
            try await TranscribeJobTracking.awaitCompletion(of: job, reporting: progress)
        } onCancel: { _ in
            Task { @MainActor in job.cancel() }
        }
        guard let sessionID,
              let saved = await TranscriptSessionStore.entityAndText(forID: sessionID) else {
            throw TranscriptionJobFailure(message: "The transcription finished without producing a transcript.")
        }
        await MainActor.run { appModel.openSession(id: sessionID) }
        return .result(value: saved.entity, dialog: "Transcribed \(displayTitle).")
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
            await MainActor.run { appModel.returnHome() }
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

/// Ask a question about your transcripts, answered on-device by Apple Intelligence. With **no**
/// transcript given, it searches the **whole library** — "what did Sergio and I decide at the last
/// meeting?" resolves to the right session and answers from it (Flagship A, Siri semantic Q&A). Give
/// a specific transcript and it answers grounded in just that one. Degrades gracefully to a spoken
/// explanation when Apple Intelligence isn't available.
public struct AskTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Ask a Transcript"
    public static let description = IntentDescription(
        "Ask a question about your transcripts. With no transcript chosen, Apple Intelligence searches your whole library on-device; choose one to ask about just that transcript.")

    @Parameter(title: "Question", description: "What you want to know about your transcripts.")
    public var question: String

    @Parameter(title: "Transcript", description: "Which transcript to ask about. Leave empty to search your whole library.")
    public var session: TranscriptSessionEntity?

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // A specific transcript → grounded single-session Q&A (the existing behavior).
        if let session, let id = UUID(uuidString: session.id) {
            guard let target = await TranscriptSessionStore.entityAndText(forID: id) else {
                throw TranscriptionIntentError.noTranscripts
            }
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

        // No transcript chosen → library-wide semantic RAG over the named Spotlight index.
        switch await TranscriptLibraryAssistant.ask(question) {
        case .success(let answer):
            return .result(value: answer, dialog: "\(answer)")
        case .failure(.unavailable):
            return .result(value: "", dialog: "\(SessionIntelligence.currentStatus().message)")
        case .failure(.failed):
            return .result(value: "", dialog: "Something went wrong. Please try again.")
        }
    }
}

// MARK: - Summarize (Foundation Models)

/// Summarize a transcript, answered on-device by Apple Intelligence. Defaults to the latest
/// recording, mirroring `AskTranscriptIntent`'s degrade-gracefully behavior.
public struct SummarizeTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Summarize Transcript"
    public static let description = IntentDescription(
        "Summarize a transcript. Apple Intelligence summarizes on-device from the transcript.")

    @Parameter(title: "Transcript", description: "Which transcript to summarize. Defaults to your latest.")
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
            let summary = try await intelligence.summarize(transcript: target.fullText)
            return .result(value: summary, dialog: "\(summary)")
        } catch {
            return .result(value: "", dialog: "\(SessionIntelligence.errorMessage(for: error))")
        }
    }
}

// MARK: - Export

/// Export a transcript as a downloadable file — plain text, Markdown, SRT, or WebVTT.
/// Defaults to the latest recording. Returns an `ExportedTranscriptFileEntity` (a `FileEntity`,
/// not a bare `IntentFile`) so Shortcuts can save/share/AirDrop it like any other file result
/// *and* the system carries the export's ownership signal — an exported transcript leaves the
/// app boundary, so the entity reports `.shared` and Siri confirms before an automated share.
public struct ExportTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Export Transcript"
    public static let description = IntentDescription(
        "Export a transcript as a file. Defaults to your latest transcript.")

    @Parameter(title: "Transcript", description: "Which transcript to export. Defaults to your latest.")
    public var session: TranscriptSessionEntity?

    @Parameter(title: "Format", description: "The export file format.", default: .plainText)
    public var format: TranscriptExport.Format

    public init() {}

    public func perform() async throws
        -> some IntentResult & ReturnsValue<ExportedTranscriptFileEntity> & ProvidesDialog {
        let resolved: (title: String, data: Data)?
        if let session, let id = UUID(uuidString: session.id) {
            resolved = await TranscriptSessionStore.exportedData(forID: id, as: format)
        } else {
            resolved = await TranscriptSessionStore.latestExportedData(as: format)
        }
        guard let resolved, !resolved.data.isEmpty else { throw TranscriptionIntentError.noTranscripts }

        let safeName = resolved.title.isEmpty ? "Transcript" : resolved.title
        // Write the rendered transcript to a uniquely-scoped temp file so the returned
        // `FileEntity` has a real on-disk URL (its identity), while the file the user sees keeps
        // a clean `title.ext` name and repeated exports never collide.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntentExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(safeName).\(format.fileExtension)")
        try resolved.data.write(to: fileURL)

        let entity = try ExportedTranscriptFileEntity(id: .file(url: fileURL), title: safeName)
        return .result(value: entity, dialog: "Exported \(safeName).")
    }
}

extension TranscriptExport.Format: AppEnum {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Transcript Export Format")
    }

    public static var caseDisplayRepresentations: [TranscriptExport.Format: DisplayRepresentation] {
        [.plainText: "Plain Text", .markdown: "Markdown", .srt: "SubRip (.srt)", .vtt: "WebVTT (.vtt)",
         .docx: "Word (.docx)"]
    }
}

// MARK: - Open

/// Open a transcript in the app — also powers tapping a Spotlight result.
public struct OpenTranscriptIntent: AppIntent, OpenIntent {
    public static let title: LocalizedStringResource = "Open Transcript"
    public static let description = IntentDescription("Open a transcript in Transcription Studio.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Transcript")
    public var target: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent {
        let id = UUID(uuidString: target.id)
        await MainActor.run {
            if let id { appModel.openSession(id: id) } else { appModel.returnHome() }
        }
        return .result(opensIntent: OpenAppIntent())
    }
}

/// Open the Library — the first-class form of `SearchTranscriptsIntent`'s `openLibrary` flag,
/// for "just open my library" with no search involved.
public struct OpenLibraryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Library"
    public static let description = IntentDescription("Open the Library in Transcription Studio.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent {
        await MainActor.run { appModel.returnHome() }
        return .result(opensIntent: OpenAppIntent())
    }
}

// MARK: - App Shortcuts

/// Zero-setup Siri phrases. `\(.applicationName)` binds each phrase to the app. Apple caps a
/// provider at 10 promoted shortcuts (`AppShortcutContract.systemLimit`); `DeleteTranscriptIntent`,
/// `ExportTranscriptIntent`, `OpenLibraryIntent`, and `GetRecordingStatusIntent` stay reachable
/// via the Shortcuts app / Spotlight without a canned phrase — freeing room for the
/// higher-value `OpenInspectorIntent` (every platform) and `TranscribeLinkIntent` (macOS only,
/// since URL ingest doesn't exist on iOS) — so the promoted set stays at exactly 10 on macOS
/// (9 on iOS, no Link) — see `shortcutCountWithinSystemLimit` for the pinned per-platform count.
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

        AppShortcut(
            intent: SummarizeTranscriptIntent(),
            phrases: [
                "Summarize my last recording in \(.applicationName)",
                "Summarize my \(.applicationName) transcript"
            ],
            shortTitle: "Summarize Transcript",
            systemImageName: "text.redaction")

        AppShortcut(
            intent: OpenInspectorIntent(),
            phrases: [
                "Open the inspector in \(.applicationName)",
                "Show my \(.applicationName) inspector"
            ],
            shortTitle: "Open Inspector",
            systemImageName: "gauge.with.dots.needle.bottom.50percent")

        #if os(macOS)
        AppShortcut(
            intent: TranscribeLinkIntent(),
            phrases: [
                "Transcribe a link with \(.applicationName)",
                "Transcribe a link in \(.applicationName)"
            ],
            shortTitle: "Transcribe Link",
            systemImageName: "link")
        #endif
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
