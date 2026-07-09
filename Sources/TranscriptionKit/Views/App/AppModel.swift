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

    // Engines behind their contracts — mocks today, real engines later, same UI.
    let asr: any AsrEngine
    let diarizer: any DiarizationEngine
    /// The cross-check backend for the inspector's diarizer A/B (a second, independent run).
    let crossCheckDiarizer: any DiarizationEngine

    // Live controllers.
    public let recording: RecordingController
    public let playback: PlaybackController

    // Shell state.
    public var isInspectorPresented: Bool = false
    public var selectedSurface: AppSurface = .transcribe
    /// The session the Library should focus (set when opening a finished job's result).
    public var selectedSessionID: UUID?

    /// Designated init: the diagnostics spine is built by the caller so engines can be
    /// constructed logging through the same recorder the inspector observes.
    public init(modelContext: ModelContext,
                inspector: InspectorStore,
                recorder: PipelineRecorder,
                asr: any AsrEngine,
                diarizer: any DiarizationEngine,
                crossCheckDiarizer: any DiarizationEngine,
                captureFactory: @escaping RecordingController.CaptureFactory) {
        self.inspector = inspector
        self.recorder = recorder
        self.loadSampler = SystemLoadSampler(store: inspector)
        self.jobs = JobStore()
        self.settings = AppSettings()
        self.modelContext = modelContext
        self.asr = asr
        self.diarizer = diarizer
        self.crossCheckDiarizer = crossCheckDiarizer
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
    public static func live(captureFactory: @escaping RecordingController.CaptureFactory)
        -> AppModel {
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
                        captureFactory: captureFactory)
    }

    /// Mock-engine app model (previews, engine-less demos).
    public static func mock() -> AppModel {
        AppModel(modelContext: ModelContext(AppModelContainer.shared))
    }

    // MARK: Transcribe jobs (file / URL) — mock-backed, real loop (job → session → library).

    /// Start a transcription job for a picked/dropped file or a pasted URL. The job walks the
    /// web-app step trail, runs the (mock) ASR + diarizer over a synthesized buffer, fuses,
    /// and persists a real session so the Library populates.
    public func startTranscription(title: String, source: TranscriptionSource) {
        let runner = TranscriptionJobRunner(asr: asr,
                                            diarizer: diarizer,
                                            recorder: recorder,
                                            inspector: inspector,
                                            modelContext: modelContext,
                                            settings: settings)
        let job = runner.makeJob(title: title, source: source)
        jobs.add(job)
        job.task = Task { await runner.run(job: job, source: source) }
    }

    /// Ensure a demoable sample session exists so the Library and playback surfaces are never
    /// empty on first launch. Idempotent — seeds only when the store has no sessions.
    public func seedSampleSessionIfNeeded() {
        let descriptor = FetchDescriptor<TranscriptSession>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }
        DemoContent.seedSampleSession(into: modelContext)
    }
}

/// Where a transcription job's audio comes from.
public enum TranscriptionSource: Sendable {
    case url(String)
    case file(name: String, durationHint: TimeInterval)
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
