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

    public init(modelContext: ModelContext,
                asr: any AsrEngine = MockAsrEngine(),
                diarizer: any DiarizationEngine = MockDiarizationEngine(),
                crossCheckDiarizer: any DiarizationEngine = PreviewAltDiarizer()) {
        let inspector = InspectorStore()
        self.inspector = inspector
        self.recorder = PipelineRecorder(store: inspector)
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
                                             recorder: self.recorder,
                                             inspector: inspector,
                                             loadSampler: self.loadSampler,
                                             modelContext: modelContext,
                                             settings: self.settings)
    }

    /// Build an app model bound to the shared persistent container.
    public static func live() -> AppModel {
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
