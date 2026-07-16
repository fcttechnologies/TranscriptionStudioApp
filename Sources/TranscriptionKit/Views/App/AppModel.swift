import Foundation
import Observation
import SwiftData
import GlanceKit

/// The top-level app model — the one object every surface reads. It owns the injected
/// engines (behind their protocols, so the real WhisperKit / Sortformer engines drop in
/// with no UI change), the diagnostics spine (inspector store, load sampler, recorder),
/// the job store, live recording state, and the shared shell state (surface selection,
/// inspector visibility). Constructed once per app, handed down through the environment.
@MainActor
@Observable
public final class AppModel {
    // Diagnostics spine (the #1 requirement flows through here).
    public let inspector: InspectorStore
    public let recorder: PipelineRecorder
    public let loadSampler: SystemLoadSampler

    // Work + persistence.
    public let jobs: JobStore
    public let settings: AppSettings
    public let modelContext: ModelContext

    /// Biometric gate for opening a private session. A `var` (not an init param) so tests can
    /// swap in a fake without threading it through every constructor.
    @ObservationIgnored public var authenticator: any BiometricAuthenticating = BiometricAuthenticator()

    // Engines behind their contracts — mocks today, real engines later, same UI. These are
    // the launch-time engines the live recorder uses; transcription jobs pull their engines
    // from the per-model cache below so a Settings model change applies to the next job.
    let asr: any AsrEngine
    let diarizer: any DiarizationEngine
    /// The cross-check backend for the inspector's diarizer A/B (a second, independent run).
    let crossCheckDiarizer: any DiarizationEngine

    /// Builds a fresh ASR engine for a WhisperKit variant name (real WhisperKit in `live`,
    /// nil for mock/preview app models — which fall back to the injected `asr`).
    @ObservationIgnored let asrEngineProvider: (@MainActor (String) -> any AsrEngine)?
    /// Builds a fresh diarizer for a chosen backend (real engines in `live`, nil for mock).
    @ObservationIgnored let diarizerProvider: (@MainActor (AppSettings.DiarizerBackend) -> any DiarizationEngine)?
    /// Mac URL-ingest downloader, injected by the Mac shell (nil on iOS — no URL mode).
    @ObservationIgnored let urlDownloader: (any URLAudioDownloading)?

    // Transcription-job engine caches, keyed by model/backend, so switching models in
    // Settings doesn't re-download/re-load a model per job.
    @ObservationIgnored private var asrEngineCache: [String: any AsrEngine] = [:]
    @ObservationIgnored private var diarizerCache: [String: any DiarizationEngine] = [:]

    // Mac companion services (started on the Mac only — see `startMacCompanionServices`).
    @ObservationIgnored private var remoteJobWatcher: RemoteJobWatcher?
    @ObservationIgnored private var presenceHeartbeat: PresenceHeartbeat?

    // Live controllers.
    public let recording: RecordingController
    public let playback: PlaybackController

    // Shell state — the single-view home presents at most one sheet at a time.
    /// The sheet the shell is presenting (nil → the bare feed). Set by the toolbar
    /// controls, row taps, the mini-player, and the navigating App Intents.
    public var activeSheet: StudioSheet?

    /// Close every presentation and return to the bare feed (Siri "open my library").
    public func returnHome() {
        activeSheet = nil
    }

    /// Present a saved session's transcript (a row tap, a finished recording, Spotlight,
    /// `OpenTranscriptIntent`). Opening a session is the app's clearest "this is the active /
    /// last-opened transcript" signal, so it's also where we donate that session to the system
    /// as a relevant entity — "summarize this" / "ask about this" then resolve to it without a
    /// disambiguation turn (see `SessionRelevance`).
    public func openSession(id: UUID) {
        let isPrivate = session(forID: id)?.isPrivate ?? false
        if PrivacyGate.requiresAuthentication(isPrivate: isPrivate) {
            // Private: gate on a biometric unlock before anything is revealed (async).
            Task { await unlockAndPresent(id: id) }
        } else {
            // Non-private: present immediately (synchronous, as before).
            present(id: id, isPrivate: false)
        }
    }

    /// The private-session path: clear a biometric unlock, then present. A private session is
    /// never donated to the assistant. Internal (not private) so the gate is deterministically
    /// unit-tested with a fake authenticator.
    func unlockAndPresent(id: UUID) async {
        guard await authenticator.authenticate(reason: "Unlock this private session.") else { return }
        present(id: id, isPrivate: true)
    }

    /// Present the session sheet and — unless it's private — donate it as the relevant entity.
    private func present(id: UUID, isPrivate: Bool) {
        activeSheet = .session(id)
        if PrivacyGate.isEligibleForAssistant(isPrivate: isPrivate) {
            SessionRelevance.donateActiveSession(id: id)
        }
    }

    /// Resolve a session by id in the shared context (nil if it's gone).
    private func session(forID id: UUID) -> TranscriptSession? {
        let descriptor = FetchDescriptor<TranscriptSession>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    /// Start a recording from anywhere in the shell (the "+" menu, ⌘N, the intent path
    /// funnels through `recording.start` directly). Preflights the permissions the mode
    /// needs — a missing grant surfaces as a toast (with a path to Settings), never a dead
    /// recording — then clears any loaded playback, starts capture, and expands the live
    /// recording sheet.
    public func requestRecording(mode: RecordingController.Mode) {
        guard !recording.isActive else {
            activeSheet = .liveRecording
            return
        }
        switch mode {
        case .room:
            // .notDetermined proceeds — the capture source itself prompts on first use.
            if MicrophonePermission.preflight() == .denied {
                ToastCenter.shared.show(.microphoneDenied { [weak self] in
                    self?.activeSheet = .settings
                })
                return
            }
        case .meeting:
            switch ScreenCapturePermission.preflight() {
            case .granted, .needsRestart:
                break
            case .notDetermined, .denied:
                // Request right here (prompts on first use); macOS then needs a relaunch
                // before capture works, and a denial routes through Settings.
                switch ScreenCapturePermission.request() {
                case .granted:
                    break
                case .needsRestart:
                    ToastCenter.shared.show(.screenRecordingNeedsRestart())
                    return
                case .notDetermined, .denied:
                    ToastCenter.shared.show(.screenRecordingNeeded { [weak self] in
                        self?.activeSheet = .settings
                    })
                    return
                }
            }
        }
        playback.unload()
        recording.start(mode: mode)
        activeSheet = .liveRecording
    }

    /// Stop the live recording and open the saved session's transcript once the engines
    /// finish draining. The mini-player and the live sheet both route their Stop here.
    public func stopRecordingAndOpen() {
        Task { [weak self] in
            guard let self else { return }
            if let id = await self.recording.stop() {
                await TranscriptionIntentDonations.donateStopRecording()
                self.openSession(id: id)
            } else if self.activeSheet == .liveRecording {
                self.activeSheet = nil
            }
        }
    }

    /// Launch-time model-warmup state, so a surface can show unobtrusive "preparing the
    /// speech model" feedback the first time (see `prewarmDefaultEngine`).
    public private(set) var enginePrewarmState: EnginePrewarmState = .idle

    /// Designated init: the diagnostics spine is built by the caller so engines can be
    /// constructed logging through the same recorder the inspector observes.
    public init(modelContext: ModelContext,
                inspector: InspectorStore,
                recorder: PipelineRecorder,
                asr: any AsrEngine,
                diarizer: any DiarizationEngine,
                crossCheckDiarizer: any DiarizationEngine,
                captureFactory: @escaping RecordingController.CaptureFactory,
                asrEngineProvider: (@MainActor (String) -> any AsrEngine)? = nil,
                diarizerProvider: (@MainActor (AppSettings.DiarizerBackend) -> any DiarizationEngine)? = nil,
                urlDownloader: (any URLAudioDownloading)? = nil) {
        self.inspector = inspector
        self.recorder = recorder
        self.loadSampler = SystemLoadSampler(store: inspector)
        self.jobs = JobStore()
        self.settings = AppSettings()
        self.modelContext = modelContext
        self.asr = asr
        self.diarizer = diarizer
        self.crossCheckDiarizer = crossCheckDiarizer
        self.asrEngineProvider = asrEngineProvider
        self.diarizerProvider = diarizerProvider
        self.urlDownloader = urlDownloader
        self.playback = PlaybackController()
        self.recording = RecordingController(asr: asr,
                                             diarizer: diarizer,
                                             recorder: recorder,
                                             inspector: inspector,
                                             loadSampler: self.loadSampler,
                                             modelContext: modelContext,
                                             settings: self.settings,
                                             captureFactory: captureFactory)
        registerActivityActions()
    }

    /// Wire the Live Activity buttons' app-process trampolines (GlanceKit's
    /// `StudioActivityActions`) to the real controllers. The activity intents perform in this
    /// process, so registering here — once, when the model is built — is what makes the Lock
    /// Screen / Dynamic Island Stop, pause and play buttons act.
    private func registerActivityActions() {
        #if os(iOS)
        StudioActivityActions.stopRecording = { [weak self] in
            guard let self else { return }
            if let id = await self.recording.stop() {
                await TranscriptionIntentDonations.donateStopRecording()
                self.openSession(id: id)
            } else if self.activeSheet == .liveRecording {
                self.activeSheet = nil
            }
        }
        StudioActivityActions.toggleRecordingPause = { [weak self] in
            guard let recording = self?.recording else { return }
            recording.isPaused ? recording.resume() : recording.pause()
        }
        StudioActivityActions.togglePlayback = { [weak self] in
            self?.playback.togglePlayPause()
        }
        #endif
    }

    /// Mock-default convenience (previews, tests, engine-less demos).
    public convenience init(modelContext: ModelContext,
                            asr: any AsrEngine = MockAsrEngine(),
                            diarizer: any DiarizationEngine = MockDiarizationEngine(),
                            crossCheckDiarizer: any DiarizationEngine = PreviewAltDiarizer(),
                            captureFactory: @escaping RecordingController.CaptureFactory =
                                RecordingController.mockCaptureFactory) {
        let inspector = InspectorStore()
        self.init(modelContext: modelContext,
                  inspector: inspector,
                  recorder: PipelineRecorder(store: inspector),
                  asr: asr,
                  diarizer: diarizer,
                  crossCheckDiarizer: crossCheckDiarizer,
                  captureFactory: captureFactory)
    }

    /// Build the real app: WhisperKit ASR, the default diarization backend (the other
    /// backend wired as the inspector's A/B cross-check), the shared persistent container,
    /// and the platform's hardware capture factory (injected by each shell — mic on both
    /// platforms, ScreenCaptureKit meeting capture on the Mac).
    public static func live(captureFactory: @escaping RecordingController.CaptureFactory,
                            urlDownloader: (any URLAudioDownloading)? = nil) -> AppModel {
        let inspector = InspectorStore()
        // Additive MetricKit state reporting: the live recorder tags each pipeline stage as an
        // app state so a production hang/hitch/crash is attributed to the stage it occurred in
        // (the mock/preview recorder above leaves this nil).
        let recorder = PipelineRecorder(store: inspector, stateReporter: PipelineStateReporter.shared)
        let backend = DiarizationBackend.default
        let crossCheck: DiarizationBackend = backend == .sortformer ? .speakerKit : .sortformer
        return AppModel(modelContext: AppModelContainer.localContext(),
                        inspector: inspector,
                        recorder: recorder,
                        asr: WhisperKitAsrEngine(),
                        diarizer: backend.makeEngine(recorder: recorder),
                        crossCheckDiarizer: crossCheck.makeEngine(recorder: recorder),
                        captureFactory: captureFactory,
                        asrEngineProvider: { WhisperKitAsrEngine(modelName: $0) },
                        diarizerProvider: { settingsBackend in
                            let backend: DiarizationBackend =
                                settingsBackend == .sortformer ? .sortformer : .speakerKit
                            return backend.makeEngine(recorder: recorder)
                        },
                        urlDownloader: urlDownloader)
    }

    /// Mock-engine app model (previews, engine-less demos).
    public static func mock() -> AppModel {
        AppModel(modelContext: AppModelContainer.localContext())
    }

    // MARK: Transcribe jobs (file / URL) — the real pipeline (ingest → diarize → ASR → fuse).

    /// Start a transcription job for a picked/dropped file or a pasted URL. Runs the real
    /// pipeline (`TranscriptionService`) with the engines for the currently-selected model +
    /// diarizer backend, walking the web-app step trail and persisting a real session. Returns
    /// the created `TranscriptionJob` so a caller that needs to follow the job to completion —
    /// the long-running `TranscribeFileIntent`/`TranscribeLinkIntent` reporting Siri/Shortcuts
    /// progress and honoring cancellation — can observe it; fire-and-forget callers ignore it.
    @discardableResult
    public func startTranscription(title: String, source: TranscriptionSource) -> TranscriptionJob {
        let service = TranscriptionService(asrEngine: transcriptionAsrEngine(for: settings.whisperModel),
                                           diarizer: transcriptionDiarizer(for: settings.diarizerBackend),
                                           modelContext: modelContext,
                                           recorder: recorder,
                                           inspector: inspector,
                                           wordTimestamps: settings.wordTimestamps,
                                           modelName: settings.whisperModel.whisperKitVariant)
        switch source {
        case .file(let url):
            let job = TranscriptionJob(title: title, steps: TranscriptionService.fileJobSteps)
            jobs.add(job)
            BackgroundExecution.run(job: job, title: title) { await service.runFileJob(fileURL: url, job: job) }
            return job
        case .url(let string):
            let job = TranscriptionJob(title: title, steps: TranscriptionService.urlJobSteps)
            jobs.add(job)
            guard let downloader = urlDownloader else {
                // URL ingest is Mac-only; the URL field isn't shown on iOS, so this is a guard.
                job.fail("URL transcription isn't available on this device.")
                return job
            }
            BackgroundExecution.run(job: job, title: title) { await service.runURLJob(urlString: string, downloader: downloader, job: job) }
            return job
        }
    }

    // MARK: Companion link routing (iOS queues, Mac transcribes)

    /// Submit a link for transcription from the "+" menu or the Share extension. On a device with
    /// the URL downloader (Mac) it transcribes locally; elsewhere (iOS) it queues a
    /// `.pendingRemote` session for a Mac to claim and transcribe over CloudKit. Routing never
    /// depends on Mac presence — a link always queues; presence is display only.
    public func submitLink(urlString: String, title: String) {
        switch LinkSubmissionRoute.decide(hasURLDownloader: urlDownloader != nil) {
        case .local:
            startTranscription(title: title, source: .url(urlString))
        case .remote:
            queueRemoteLink(urlString: urlString, title: title)
        }
    }

    /// Create and persist a `.pendingRemote` URL session (iOS) — the queued job a Mac claims and
    /// transcribes, its result syncing back via CloudKit.
    private func queueRemoteLink(urlString: String, title: String) {
        let session = TranscriptSession(title: title, kind: .urlTranscription)
        session.sourceURLString = urlString
        session.status = .pendingRemote
        modelContext.insert(session)
        try? modelContext.save()
    }

    // MARK: Mac companion services (watcher + presence heartbeat)

    /// Start the Mac-side companion services — the remote-job watcher (claims + transcribes links
    /// queued from iOS) and the presence heartbeat (writes a last-seen row iOS reads). A no-op on
    /// a device without the URL downloader (iOS), and idempotent, so it's safe to call on every
    /// launch. Call once the model container is live (from the Mac shell's launch task).
    public func startMacCompanionServices() {
        guard urlDownloader != nil, remoteJobWatcher == nil else { return }
        let deviceID = CompanionDevice.identifier

        let heartbeat = PresenceHeartbeat(modelContext: modelContext, deviceID: deviceID,
                                          deviceName: CompanionDevice.name)
        heartbeat.start()
        presenceHeartbeat = heartbeat

        let watcher = RemoteJobWatcher(modelContext: modelContext, deviceID: deviceID,
                                       process: { [weak self] session in
            await self?.processClaimedRemoteJob(session)
        })
        watcher.start()
        remoteJobWatcher = watcher
    }

    /// Run the URL pipeline into an already-claimed remote session, surfacing progress in the
    /// Mac's own In Progress feed. The claim (status → `.inProgress`, marker set) has already been
    /// persisted by the watcher; the pipeline fills the session in and writes the completed (or
    /// failed) result back to the shared store, where it syncs to the phone.
    private func processClaimedRemoteJob(_ session: TranscriptSession) async {
        guard let downloader = urlDownloader else { return }
        let service = TranscriptionService(asrEngine: transcriptionAsrEngine(for: settings.whisperModel),
                                           diarizer: transcriptionDiarizer(for: settings.diarizerBackend),
                                           modelContext: modelContext,
                                           recorder: recorder,
                                           inspector: inspector,
                                           wordTimestamps: settings.wordTimestamps,
                                           modelName: settings.whisperModel.whisperKitVariant)
        let job = TranscriptionJob(title: session.title, steps: TranscriptionService.urlJobSteps)
        jobs.add(job)
        await service.runURLJob(on: session, isNewSession: false, downloader: downloader, job: job)
    }

    /// The cached ASR engine for a chosen model (built once per variant). Mock/preview app
    /// models have no provider and reuse the injected `asr`.
    private func transcriptionAsrEngine(for model: AppSettings.WhisperModel) -> any AsrEngine {
        let variant = model.whisperKitVariant
        if let cached = asrEngineCache[variant] { return cached }
        let engine = asrEngineProvider?(variant) ?? asr
        asrEngineCache[variant] = engine
        return engine
    }

    /// The cached diarizer for a chosen backend. Mock/preview app models reuse `diarizer`.
    private func transcriptionDiarizer(for backend: AppSettings.DiarizerBackend) -> any DiarizationEngine {
        if let cached = diarizerCache[backend.rawValue] { return cached }
        let engine = diarizerProvider?(backend) ?? diarizer
        diarizerCache[backend.rawValue] = engine
        return engine
    }

    /// Warm the default transcription model at launch so the first job doesn't eat the
    /// one-time WhisperKit model compile. On Apple Silicon the first-ever load of
    /// `large-v3-turbo` compiles the CoreML/ANE program (~85s cold); the compiled artifact
    /// then caches to disk, so every later load is ~seconds. Warming it up front — visibly,
    /// during launch — pays that one-time cost once instead of silently stalling the user's
    /// first transcription. The compile cache is per-model on disk, so warming the
    /// transcription engine also warms the artifact the live-recording engine reuses.
    /// Idempotent; a no-op for mock/preview models (their `prepare()` is instant).
    public func prewarmDefaultEngine() {
        guard case .idle = enginePrewarmState else { return }
        enginePrewarmState = .preparing(phase: "Preparing speech model…", fraction: nil)
        let engine = transcriptionAsrEngine(for: settings.whisperModel)
        Task {
            do {
                try await engine.prepare { progress in
                    Task { @MainActor in
                        self.enginePrewarmState = .preparing(phase: progress.phase, fraction: progress.fraction)
                    }
                }
                self.enginePrewarmState = .ready
            } catch {
                // A warmup failure isn't fatal — the first real job retries prepare() and
                // surfaces the error there; here we just stop showing "preparing".
                self.enginePrewarmState = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-warm the engine for the currently-selected model. Call when the user switches models
    /// in Settings so the new model downloads/compiles immediately (with visible progress),
    /// instead of silently on the next job or only after a relaunch (the force-quit workaround).
    public func prewarmSelectedModel() {
        enginePrewarmState = .idle
        prewarmDefaultEngine()
    }

}

/// Launch-time speech-model warmup state (see `AppModel.prewarmDefaultEngine`).
public enum EnginePrewarmState: Equatable, Sendable {
    case idle
    case preparing(phase: String, fraction: Double?)
    case ready
    case failed(String)

    /// True while the model is still warming — the window where a surface shows feedback.
    public var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }
}

/// Where a transcription job's audio comes from.
public enum TranscriptionSource: Sendable {
    case url(String)
    /// A picked/dropped media file — carries the real (possibly security-scoped) URL so the
    /// pipeline can ingest the actual bytes.
    case file(URL)
}

/// The sheets the single-view shell can present — one at a time, all dismissed by the
/// circular close. `Identifiable` so one `.sheet(item:)` routes every presentation.
public enum StudioSheet: Equatable, Identifiable, Sendable {
    case settings
    case inspector
    /// The full live-recording view (the mini-player's expanded form while recording).
    case liveRecording
    /// The macOS "Insert link" prompt (URL ingest is Mac-only).
    case insertLink
    /// Library-wide semantic Q&A (Flagship A) — ask across every saved transcript.
    case askLibrary
    /// A saved session's transcript.
    case session(UUID)
    /// Draft-then-confirm: review an extracted `TranscriptEvent` before adding it to Calendar.
    case confirmCalendarEvent(UUID)
    /// Draft-then-confirm: review an extracted `TranscriptActionItem` before adding it to Reminders.
    case confirmReminder(UUID)
    #if os(iOS)
    /// Map a session's diarized speakers to contacts (the system contact picker is iOS-only).
    case assignSpeakers(UUID)
    #endif

    public var id: String {
        switch self {
        case .settings: "settings"
        case .inspector: "inspector"
        case .liveRecording: "liveRecording"
        case .insertLink: "insertLink"
        case .askLibrary: "askLibrary"
        case .session(let id): "session-\(id.uuidString)"
        case .confirmCalendarEvent(let id): "confirmEvent-\(id.uuidString)"
        case .confirmReminder(let id): "confirmReminder-\(id.uuidString)"
        #if os(iOS)
        case .assignSpeakers(let id): "assignSpeakers-\(id.uuidString)"
        #endif
        }
    }
}
