import Foundation
import SwiftData

/// Orchestrates a transcription job end to end — prepare → ingest → diarize → ASR → fuse →
/// archive → persist — with every stage timed and recorded through `PipelineRecorder` (the
/// app's #1 requirement: nothing here runs unlogged). `@MainActor`: it drives
/// `TranscriptionJob` progress (itself `@MainActor`) and writes through a SwiftData
/// `ModelContext` (not `Sendable` — one context per writer is the supported SwiftData pattern).
///
/// One service is built per job (by `AppModel.startTranscription`), carrying the engines
/// resolved for the currently-selected model + diarizer backend and the job's decode options.
@MainActor
final class TranscriptionService {
    /// Web-app parity, with a leading model-preparation step (WhisperKit/diarizer download +
    /// load) and a diarization pass folded into "Transcribing".
    static let fileJobSteps = ["Preparing", "Reading file", "Transcribing", "Saving"]
    /// Mirrors the web app's job steps (`Downloading audio` → `Transcribing` →
    /// `Cleaning up temp files`); `Preparing` + `Saving` are new (model prep + persistence,
    /// neither of which the web app had).
    static let urlJobSteps = ["Preparing", "Downloading audio", "Transcribing", "Saving", "Cleaning up"]

    private let asrEngine: any AsrEngine
    private let diarizer: any DiarizationEngine
    private let modelContext: ModelContext
    private let recorder: PipelineRecorder
    private let inspector: InspectorStore
    private let wordTimestamps: Bool
    private let modelName: String
    private let titleGenerator: TitleGenerator
    private let highlightsExtractor: HighlightsExtractor

    /// Set by `prepareEngines`; false means the diarizer couldn't load and the job proceeds
    /// with speakers unknown rather than failing.
    private var diarizerReady = false

    init(asrEngine: any AsrEngine,
                diarizer: any DiarizationEngine,
                modelContext: ModelContext,
                recorder: PipelineRecorder,
                inspector: InspectorStore,
                wordTimestamps: Bool = false,
                modelName: String = "",
                titleGenerator: TitleGenerator = TitleGenerator(),
                highlightsExtractor: HighlightsExtractor = HighlightsExtractor()) {
        self.asrEngine = asrEngine
        self.diarizer = diarizer
        self.modelContext = modelContext
        self.recorder = recorder
        self.inspector = inspector
        self.wordTimestamps = wordTimestamps
        self.modelName = modelName
        self.titleGenerator = titleGenerator
        self.highlightsExtractor = highlightsExtractor
    }

    /// `PipelineRecorder.time` is `nonisolated` and runs its operation off the main
    /// actor — fine for actor-isolated engines, but this service's operations close over
    /// `@MainActor` state (the job, the `ModelContext`), so this mirrors that convenience
    /// while staying on the main actor throughout, then logs through the same
    /// `recorder.record` seam every other pipeline component uses.
    private func timed<T>(_ stage: PipelineStage, sessionID: UUID, _ message: String,
                          metadata: [String: String] = [:],
                          _ operation: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await operation()
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        recorder.record(PipelineEvent(sessionID: sessionID, stage: stage, message: message,
                                      duration: seconds, metadata: metadata))
        return result
    }

    // MARK: - File job (both platforms)

    /// Ingests a dropped/picked media file, transcribes + diarizes it, and persists the
    /// session. Returns the new session's ID on success; `job` carries the error on failure.
    @discardableResult
    func runFileJob(fileURL: URL, job: TranscriptionJob) async -> UUID? {
        let sessionID = UUID()
        let session = TranscriptSession(title: fileURL.deletingPathExtension().lastPathComponent,
                                        kind: .fileTranscription)
        session.id = sessionID

        do {
            try await prepareEngines(job: job, sessionID: sessionID)

            job.advance(to: 1, stageText: "Reading file…", progress: 0.16)
            let samples = try await ingestFile(fileURL: fileURL, sessionID: sessionID)

            try await transcribeAndPersist(samples: samples, session: session, job: job,
                                           transcribeStep: 2, saveStep: 3, sessionID: sessionID)
            job.finish(resultSessionID: sessionID)
            return sessionID
        } catch {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .ingest, level: .error,
                                          message: "File job failed",
                                          metadata: ["error": error.localizedDescription]))
            job.fail(error.localizedDescription)
            return nil
        }
    }

    /// Loads a media file to 16 kHz mono samples, holding security-scoped access for the
    /// span of the read — a `fileImporter`/`dropDestination` URL points outside the app
    /// sandbox and reading it without the scope silently fails (especially on iOS).
    private func ingestFile(fileURL: URL, sessionID: UUID) async throws -> [Float] {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        return try await timed(.ingest, sessionID: sessionID, "File ingest",
                               metadata: ["extension": fileURL.pathExtension]) {
            try FileIngestService.loadSamples(from: fileURL)
        }
    }

    // MARK: - URL job (Mac only — the orchestration is shared; only Mac ever calls it)

    /// Downloads a URL's audio, transcribes + diarizes it, and persists the session —
    /// mirrors the web app's download → transcribe → cleanup flow with model prep,
    /// diarization, and persistence added.
    @discardableResult
    func runURLJob(urlString: String, downloader: any URLAudioDownloading,
                          job: TranscriptionJob) async -> UUID? {
        let session = TranscriptSession(title: urlString, kind: .urlTranscription)
        session.id = UUID()
        session.sourceURLString = urlString
        return await runURLJob(on: session, isNewSession: true, downloader: downloader, job: job)
    }

    /// Process a URL job into an **existing** session — the companion path: a `.pendingRemote`
    /// link queued on iOS, already claimed here on the Mac (status `.inProgress`, claim marker
    /// set) and living in the shared store. `isNewSession` is `false`, so the session is updated
    /// in place rather than inserted, and a failure is persisted as `.failed` so the originating
    /// phone sees the outcome sync back instead of a job stuck "transcribing" forever.
    @discardableResult
    func runURLJob(on session: TranscriptSession, isNewSession: Bool,
                          downloader: any URLAudioDownloading, job: TranscriptionJob) async -> UUID? {
        let sessionID = session.id
        let urlString = session.sourceURLString ?? session.title

        do {
            try await prepareEngines(job: job, sessionID: sessionID)

            job.advance(to: 1, stageText: "Downloading audio…", progress: 0.16)
            let audioURL = try await timed(.download, sessionID: sessionID, "yt-dlp download") {
                try await downloader.downloadAudio(url: urlString, jobID: sessionID) { [weak job] progress in
                    guard let job, let fraction = progress.fractionCompleted else { return }
                    Task { @MainActor in
                        job.advance(to: 1, stageText: "Downloading audio… \(Int(fraction * 100))%",
                                   progress: 0.16 + fraction * 0.24)
                    }
                }
            }
            let samples = try await timed(.ingest, sessionID: sessionID, "Load downloaded audio") {
                try FileIngestService.loadSamples(from: audioURL)
            }

            try await transcribeAndPersist(samples: samples, session: session, job: job,
                                           transcribeStep: 2, saveStep: 3, sessionID: sessionID,
                                           isNewSession: isNewSession)

            job.advance(to: 4, stageText: "Cleaning up…", progress: 0.98)
            await timed(.system, sessionID: sessionID, "Cleanup temp files") {
                await downloader.cleanup(jobID: sessionID)
            }

            job.finish(resultSessionID: sessionID)
            return sessionID
        } catch {
            await downloader.cleanup(jobID: sessionID)
            if !isNewSession {
                // A claimed remote job: record the failure in the shared store so the phone that
                // queued it sees "failed" sync back rather than a job stuck mid-flight.
                session.status = .failed
                session.errorMessage = error.localizedDescription
                try? modelContext.save()
            }
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .download, level: .error,
                                          message: "URL job failed",
                                          metadata: ["error": error.localizedDescription]))
            job.fail(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Shared stages

    /// Download + load both engines (step 0). ASR failure fails the job (there's no
    /// transcript without it); diarizer failure is logged and swallowed so the job still
    /// produces a transcript with speakers unknown.
    private func prepareEngines(job: TranscriptionJob, sessionID: UUID) async throws {
        job.advance(to: 0, stageText: "Preparing…", progress: 0.02)
        try await timed(.system, sessionID: sessionID, "Prepare speech model",
                        metadata: ["model": modelName]) {
            try await asrEngine.prepare { progress in
                let fraction = progress.fraction
                let phase = progress.phase
                Task { @MainActor in
                    let text = fraction.map { "\(phase)… \(Int($0 * 100))%" } ?? "\(phase)…"
                    job.advance(to: 0, stageText: text, progress: 0.02 + (fraction ?? 0) * 0.12)
                }
            }
        }

        do {
            try await timed(.system, sessionID: sessionID, "Prepare diarizer",
                            metadata: ["backend": diarizer.backendName]) {
                try await diarizer.prepare { _ in }
            }
            diarizerReady = true
        } catch {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .diarizeCommit, level: .warning,
                                          message: "Diarizer unavailable — continuing with speakers unknown",
                                          metadata: ["error": error.localizedDescription]))
            diarizerReady = false
        }
    }

    /// Archive audio → diarize → ASR → fuse → persist. Shared by both job kinds.
    private func transcribeAndPersist(samples: [Float], session: TranscriptSession,
                                      job: TranscriptionJob, transcribeStep: Int, saveStep: Int,
                                      sessionID: UUID, isNewSession: Bool = true) async throws {
        session.duration = Double(samples.count) / AudioChunk.sampleRate
        archiveAudio(samples: samples, session: session, sessionID: sessionID)

        job.advance(to: transcribeStep, stageText: "Transcribing…", progress: 0.55)
        let turns = await diarize(samples: samples, sessionID: sessionID)

        let segments = try await timed(.asr, sessionID: sessionID, "Transcribe",
                                       metadata: ["sampleCount": "\(samples.count)", "model": modelName]) {
            try await asrEngine.transcribe(samples: samples, track: .mixed, wordTimestamps: wordTimestamps)
        }

        job.advance(to: transcribeStep, stageText: "Attributing speakers…", progress: 0.85)
        let attributed = TranscriptFuser.attribute(asr: segments, turns: turns)
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .fusion, message: "Fused transcript",
                                      metadata: ["segments": "\(attributed.count)"]))

        job.advance(to: saveStep, stageText: "Saving…", progress: 0.92)
        try await persist(session: session, attributed: attributed, sessionID: sessionID,
                          isNewSession: isNewSession)
        titleGenerator.applyGeneratedTitle(to: session, modelContext: modelContext)
        // The FM extraction substrate — off the critical path, after the transcript is saved.
        highlightsExtractor.schedule(for: session, modelContext: modelContext)
    }

    /// Diarize the buffer through the app's diarizer, pushing raw frames to the inspector.
    /// Best-effort: an unprepared or failing diarizer yields no turns (speakers unknown)
    /// rather than failing the job — the pipeline event records why.
    private func diarize(samples: [Float], sessionID: UUID) async -> [SpeakerTurn] {
        guard diarizerReady else { return [] }
        do {
            let result = try await timed(.diarizeCommit, sessionID: sessionID, "Diarize buffer",
                                         metadata: ["backend": diarizer.backendName]) {
                try await diarizer.diarize(samples: samples)
            }
            inspector.setSpeakerFrames(result.frames, for: sessionID)
            return result.turns
        } catch {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .diarizeCommit, level: .warning,
                                          message: "Diarization failed — continuing with speakers unknown",
                                          metadata: ["error": error.localizedDescription]))
            return []
        }
    }

    /// Archive the ingested 16k mono samples as compressed AAC in the session row so it's
    /// re-playable (click-to-play) and re-runnable offline. Best-effort — an encode failure
    /// leaves the session without archived audio but doesn't fail the transcription.
    private func archiveAudio(samples: [Float], session: TranscriptSession, sessionID: UUID) {
        do {
            session.audioData = try AudioFileIO.encodeAAC(samples: samples)
        } catch {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .persistence, level: .warning,
                                          message: "Audio archive failed — click-to-play unavailable",
                                          metadata: ["error": error.localizedDescription]))
        }
    }

    // MARK: - Persistence

    private func persist(session: TranscriptSession, attributed: [AttributedSegment],
                         sessionID: UUID, isNewSession: Bool = true) async throws {
        try await timed(.persistence, sessionID: sessionID, "Save session",
                        metadata: ["segments": "\(attributed.count)"]) {
            session.fullText = attributed.map(\.asr.text).joined(separator: " ")
            session.status = .complete
            session.errorMessage = nil
            session.segments = attributed.map { StoredSegment(from: $0) }
            // A claimed remote session is already in the store; only a freshly built one is inserted.
            if isNewSession { modelContext.insert(session) }
            try modelContext.save()
        }
    }
}
