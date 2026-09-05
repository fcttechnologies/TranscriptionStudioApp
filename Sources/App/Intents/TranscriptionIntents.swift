import Foundation
import AppIntents
import FCTMetrics
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
enum RecordingModeAppEnum: String, AppEnum {
    case room
    case meeting

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Recording Mode")
    }

    static var caseDisplayRepresentations: [RecordingModeAppEnum: DisplayRepresentation] {
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
enum RecordingModeAppEnum: String, AppEnum {
    case room

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Recording Mode")
    }

    static var caseDisplayRepresentations: [RecordingModeAppEnum: DisplayRepresentation] {
        [.room: "Room"]
    }

    var controllerMode: RecordingController.Mode { .room }
}
#endif

/// Start a recording. Opens the app — live capture needs the foreground process. Guards
/// against a redundant start *before* touching the recorder, so a second "start recording"
/// while one is already running throws rather than silently no-opping behind a false
/// "Recording started." dialog.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription(
        "Start a new room or meeting recording and live transcription in Transcription Studio.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Mode", description: "Room (your mic) or Meeting (system audio + mic, Mac only).",
               default: .room)
    var mode: RecordingModeAppEnum

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        func run() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
            try await MainActor.run {
                guard !appModel.recording.isRecording else { throw TranscriptionIntentError.alreadyRecording }
                appModel.playback.unload()
                appModel.readAloud.stop()
                appModel.recording.start(mode: mode.controllerMode)
                appModel.activeSheet = .liveRecording
            }
            return .result(opensIntent: OpenAppIntent(), dialog: "Recording started.")
        }
        return try await Diag.intent(TranscriptionCrumb.startRecordingIntent, run)
    }
}

/// Stop the current recording, returning the saved session and a short snippet.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription(
        "Stop the current recording in Transcription Studio and save the transcript.")

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<TranscriptSessionEntity> & ProvidesDialog {
        func run() async throws
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
        return try await Diag.intent(TranscriptionCrumb.stopRecordingIntent, run)
    }
}

/// Check whether Transcription Studio is currently recording — "am I recording?".
struct GetRecordingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recording Status"
    static let description = IntentDescription(
        "Check whether Transcription Studio is currently recording.")

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        func run() async throws
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
        return try await Diag.intent(TranscriptionCrumb.getRecordingStatusIntent, run)
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
struct TranscribeFileIntent: LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Transcribe a File"
    static let description = IntentDescription(
        "Transcribe an audio or video file with Transcription Studio.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "File", description: "The audio or video file to transcribe.",
               supportedContentTypes: [.audio, .movie])
    var file: IntentFile

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<TranscriptSessionEntity> & ProvidesDialog {
        func run() async throws
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
        return try await Diag.intent(TranscriptionCrumb.transcribeFileIntent, run)
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
struct SearchTranscriptsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Transcripts"
    static let description = IntentDescription(
        "Search your saved transcripts by title or spoken content.")

    @Parameter(title: "Search text", description: "What to look for in your transcripts.")
    var query: String

    @Parameter(title: "Open in Library", description: "Also open the Library to browse results.",
               default: false)
    var openLibrary: Bool

    @Dependency private var appModel: AppModel

    var supportedModes: IntentModes { .foreground(.dynamic) }

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<[TranscriptSessionEntity]> & ProvidesDialog {
        func run() async throws
        -> some IntentResult & ReturnsValue<[TranscriptSessionEntity]> & ProvidesDialog {
            let results = await TranscriptSessionStore.entities(matching: query)
            if openLibrary {
                try await continueInForeground(alwaysConfirm: false)
                await MainActor.run { appModel.returnHome() }
            }
            // One key with one `%lld`, pluralized by the CATALOG rather than by picking an English
            // "s" here. A suffix chosen in Swift can only ever be right for English: Spanish needs
            // "transcripciones", not a letter appended, and Russian selects among three forms by the
            // count's last digits — neither is reachable from a boolean. The plural variation per
            // language is the only place that knowledge can live.
            let dialog: IntentDialog = results.isEmpty
                ? "No transcripts match “\(query)”."
                : "Found \(results.count) transcripts."
            return .result(value: results, dialog: dialog)
        }
        return try await Diag.intent(TranscriptionCrumb.searchTranscriptsIntent, run)
    }
}

// MARK: - Latest transcript

/// Return the newest transcript's full text — "read me my last transcript".
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription(
        "Read back the full text of your most recent transcript.")

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        func run() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
            guard let latest = await TranscriptSessionStore.latestEntityAndText() else {
                throw TranscriptionIntentError.noTranscripts
            }
            let text = latest.fullText
            let dialog: IntentDialog = text.isEmpty ? "Your latest transcript is empty." : "\(text)"
            return .result(value: text, dialog: dialog)
        }
        return try await Diag.intent(TranscriptionCrumb.getLatestTranscriptIntent, run)
    }
}

// MARK: - Ask (Foundation Models Q&A)

/// Ask a question about your transcripts, answered by Apple Intelligence. With **no** transcript
/// given, it searches the **whole library** — "what did Sergio and I decide at the last meeting?"
/// resolves to the right session and answers from it (Flagship A, Siri semantic Q&A), entirely on
/// this device: `TranscriptLibraryAssistant` runs on the default `SystemLanguageModel` and never
/// escalates. Give a specific transcript and it answers grounded in just that one through
/// `SessionIntelligence`, which *does* escalate to Private Cloud Compute past the on-device context
/// budget — so the two branches make different claims and the description says both. Degrades
/// gracefully to a spoken explanation when Apple Intelligence isn't available.
struct AskTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Transcript"
    static let description = IntentDescription(
        "Ask a question about your transcripts. With no transcript chosen, Apple Intelligence searches your whole library on this device; choose one and it answers from just that transcript, using Apple's Private Cloud Compute if the transcript is long.")

    @Parameter(title: "Question", description: "What you want to know about your transcripts.")
    var question: String

    @Parameter(title: "Transcript", description: "Which transcript to ask about. Leave empty to search your whole library.")
    var session: TranscriptSessionEntity?

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        func run() async throws
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
        return try await Diag.intent(TranscriptionCrumb.askTranscriptIntent, run)
    }
}

// MARK: - Summarize (Foundation Models)

/// Summarize a transcript with Apple Intelligence. Runs on this device and escalates to Private
/// Cloud Compute for a transcript past the on-device context budget (`SessionIntelligence.generate`),
/// so the description cannot say "on-device" flatly. Defaults to the latest recording, mirroring
/// `AskTranscriptIntent`'s degrade-gracefully behavior.
struct SummarizeTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Transcript"
    static let description = IntentDescription(
        "Summarize a transcript. Apple Intelligence summarizes on this device, using Apple's Private Cloud Compute if the transcript is long.")

    @Parameter(title: "Transcript", description: "Which transcript to summarize. Defaults to your latest.")
    var session: TranscriptSessionEntity?

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        func run() async throws
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
        return try await Diag.intent(TranscriptionCrumb.summarizeTranscriptIntent, run)
    }
}

// MARK: - Export

/// Export a transcript as a downloadable file — plain text, Markdown, SRT, or WebVTT.
/// Defaults to the latest recording. Returns an `ExportedTranscriptFileEntity` (a `FileEntity`,
/// not a bare `IntentFile`) so Shortcuts can save/share/AirDrop it like any other file result
/// *and* the system carries the export's ownership signal — an exported transcript leaves the
/// app boundary, so the entity reports `.shared` and Siri confirms before an automated share.
struct ExportTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Transcript"
    static let description = IntentDescription(
        "Export a transcript as a file. Defaults to your latest transcript.")

    @Parameter(title: "Transcript", description: "Which transcript to export. Defaults to your latest.")
    var session: TranscriptSessionEntity?

    @Parameter(title: "Format", description: "The export file format.", default: .plainText)
    var format: TranscriptExport.Format

    init() {}

    func perform() async throws
        -> some IntentResult & ReturnsValue<ExportedTranscriptFileEntity> & ProvidesDialog {
        func run() async throws
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
            Diag.count(TranscriptionCounter.transcriptsExported)
            return .result(value: entity, dialog: "Exported \(safeName).")
        }
        return try await Diag.intent(TranscriptionCrumb.exportTranscriptIntent, run)
    }
}

extension TranscriptExport.Format: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Transcript Export Format")
    }

    static var caseDisplayRepresentations: [TranscriptExport.Format: DisplayRepresentation] {
        [.plainText: "Plain Text", .markdown: "Markdown", .srt: "SubRip (.srt)", .vtt: "WebVTT (.vtt)",
         .docx: "Word (.docx)"]
    }
}

// MARK: - Open

/// Open a transcript in the app — also powers tapping a Spotlight result.
struct OpenTranscriptIntent: AppIntent, OpenIntent {
    static let title: LocalizedStringResource = "Open Transcript"
    static let description = IntentDescription("Open a transcript in Transcription Studio.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Parameter(title: "Transcript")
    var target: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        func run() async throws -> some IntentResult & OpensIntent {
            let id = UUID(uuidString: target.id)
            await MainActor.run {
                if let id { appModel.openSession(id: id) } else { appModel.returnHome() }
            }
            return .result(opensIntent: OpenAppIntent())
        }
        return try await Diag.intent(TranscriptionCrumb.openTranscriptIntent, run)
    }
}

/// Open the Library — the first-class form of `SearchTranscriptsIntent`'s `openLibrary` flag,
/// for "just open my library" with no search involved.
struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Library"
    static let description = IntentDescription("Open the Library in Transcription Studio.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        func run() async throws -> some IntentResult & OpensIntent {
            await MainActor.run { appModel.returnHome() }
            return .result(opensIntent: OpenAppIntent())
        }
        return try await Diag.intent(TranscriptionCrumb.openLibraryIntent, run)
    }
}

// MARK: - Dependency registration

/// Register the live `AppModel` so intents can resolve it via `@Dependency`. Called from each
/// app shell's `init` (both platforms) so the dependency is ready whenever the app process
/// runs an intent.
enum TranscriptionAppIntents {
    @MainActor
    static func registerDependencies(appModel: AppModel) {
        // Safety: `AppDependencyManager.shared` is the framework's own singleton, `nonisolated(unsafe)`
        // in the SDK; it is reached here once, on the main actor, at launch.
        unsafe AppDependencyManager.shared.add(dependency: appModel)
    }
}
