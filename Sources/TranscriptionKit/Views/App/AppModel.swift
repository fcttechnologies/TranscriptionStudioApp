import Foundation
import Observation
import SwiftData

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

    // Live controllers.
    public let recording: RecordingController
    public let playback: PlaybackController

    // Shell state.
    public var isInspectorPresented: Bool = false
    public var selectedSurface: AppSurface = .transcribe
    /// The session the Library should focus (set when opening a finished job's result).
    public var selectedSessionID: UUID?

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
        let recorder = PipelineRecorder(store: inspector)
        let backend = DiarizationBackend.default
        let crossCheck: DiarizationBackend = backend == .sortformer ? .speakerKit : .sortformer
        return AppModel(modelContext: ModelContext(AppModelContainer.shared),
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
        AppModel(modelContext: ModelContext(AppModelContainer.shared))
    }

    // MARK: Transcribe jobs (file / URL) — the real pipeline (ingest → diarize → ASR → fuse).

    /// Start a transcription job for a picked/dropped file or a pasted URL. Runs the real
    /// pipeline (`TranscriptionService`) with the engines for the currently-selected model +
    /// diarizer backend, walking the web-app step trail and persisting a real session.
    public func startTranscription(title: String, source: TranscriptionSource) {
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
            job.task = Task { await service.runFileJob(fileURL: url, job: job) }
        case .url(let string):
            let job = TranscriptionJob(title: title, steps: TranscriptionService.urlJobSteps)
            jobs.add(job)
            guard let downloader = urlDownloader else {
                // URL ingest is Mac-only; the URL field isn't shown on iOS, so this is a guard.
                job.fail("URL transcription isn't available on this device.")
                return
            }
            job.task = Task { await service.runURLJob(urlString: string, downloader: downloader, job: job) }
        }
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

    /// Ensure a demoable sample session exists so the Library and playback surfaces are never
    /// empty on first launch. Idempotent — seeds only when the store has no sessions.
    public func seedSampleSessionIfNeeded() {
        // Seed the demo session at most ONCE ever — gated on a persisted flag, not just an empty
        // store, so deleting it makes it stay gone (an empty store on a later launch is the user
        // having cleared it, not a fresh install).
        let seededKey = "TranscriptionStudio.didSeedSampleSession"
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)

        let descriptor = FetchDescriptor<TranscriptSession>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }
        DemoContent.seedSampleSession(into: modelContext)
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

/// The app's three primary surfaces — the sidebar/tab items both shells share.
public enum AppSurface: String, CaseIterable, Identifiable, Sendable {
    case transcribe, record, library
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .transcribe: "Transcribe"
        case .record: "Record"
        case .library: "Library"
        }
    }

    public var systemImage: String {
        switch self {
        case .transcribe: "text.quote"
        case .record: "waveform.badge.microphone"
        case .library: "books.vertical"
        }
    }
}
