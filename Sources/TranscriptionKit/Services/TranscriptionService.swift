import Foundation
import SwiftData

/// Orchestrates a transcription job end to end — ingest → ASR → persistence — with every
/// stage timed and recorded through `PipelineRecorder` (the app's #1 requirement: nothing
/// here runs unlogged). `@MainActor`: it drives `TranscriptionJob` progress (itself
/// `@MainActor`) and writes through a SwiftData `ModelContext` (not `Sendable` — one
/// context per writer is the supported SwiftData pattern).
@MainActor
public final class TranscriptionService {
    /// Web-app parity: a dropped/picked file skips the download step the URL job needs.
    public static let fileJobSteps = ["Reading file", "Transcribing", "Saving"]
    /// Mirrors the web app's job steps (`Downloading audio` → `Transcribing` →
    /// `Cleaning up temp files`); `Saving` is new — the web app returned the transcript
    /// directly and never persisted it.
    public static let urlJobSteps = ["Downloading audio", "Transcribing", "Saving", "Cleaning up"]

    private let asrEngine: any AsrEngine
    private let modelContext: ModelContext
    private let recorder: PipelineRecorder

    public init(asrEngine: any AsrEngine, modelContext: ModelContext, recorder: PipelineRecorder) {
        self.asrEngine = asrEngine
        self.modelContext = modelContext
        self.recorder = recorder
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

    /// Ingests a dropped/picked media file, transcribes it, and persists the session.
    /// Returns the new session's ID on success; `job` carries the error on failure.
    @discardableResult
    public func runFileJob(fileURL: URL, job: TranscriptionJob) async -> UUID? {
        let sessionID = UUID()
        let session = TranscriptSession(title: fileURL.deletingPathExtension().lastPathComponent,
                                        kind: .fileTranscription)
        session.id = sessionID

        do {
            job.advance(to: 0, stageText: "Reading file…", progress: 0.1)
            let samples = try await timed(.ingest, sessionID: sessionID, "File ingest",
                                                  metadata: ["extension": fileURL.pathExtension]) {
                try FileIngestService.loadSamples(from: fileURL)
            }
            session.duration = Double(samples.count) / AudioChunk.sampleRate

            job.advance(to: 1, stageText: "Transcribing…", progress: 0.4)
            let segments = try await timed(.asr, sessionID: sessionID, "Transcribe",
                                                    metadata: ["sampleCount": "\(samples.count)"]) {
                try await asrEngine.transcribe(samples: samples, track: .mixed, wordTimestamps: true)
            }

            job.advance(to: 2, stageText: "Saving…", progress: 0.9)
            try await persist(session: session, segments: segments, sessionID: sessionID)

            job.finish(resultSessionID: sessionID)
            return sessionID
        } catch {
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .ingest, level: .error,
                                          message: "File job failed",
                                          metadata: ["error": String(describing: type(of: error))]))
            job.fail(error.localizedDescription)
            return nil
        }
    }

    // MARK: - URL job (Mac only — the orchestration is shared; only Mac ever calls it)

    /// Downloads a URL's audio, transcribes it, and persists the session — mirrors the
    /// web app's download → transcribe → cleanup flow with a persistence step added.
    @discardableResult
    public func runURLJob(urlString: String, downloader: any URLAudioDownloading,
                          job: TranscriptionJob) async -> UUID? {
        let sessionID = UUID()
        let session = TranscriptSession(title: urlString, kind: .urlTranscription)
        session.id = sessionID
        session.sourceURLString = urlString

        do {
            job.advance(to: 0, stageText: "Downloading audio…", progress: 0.05)
            let audioURL = try await timed(.download, sessionID: sessionID, "yt-dlp download") {
                try await downloader.downloadAudio(url: urlString, jobID: sessionID) { [weak job] progress in
                    guard let job, let fraction = progress.fractionCompleted else { return }
                    Task { @MainActor in
                        job.advance(to: 0, stageText: "Downloading audio… \(Int(fraction * 100))%",
                                   progress: 0.05 + fraction * 0.35)
                    }
                }
            }

            job.advance(to: 1, stageText: "Transcribing…", progress: 0.45)
            let samples = try await timed(.ingest, sessionID: sessionID, "Load downloaded audio") {
                try FileIngestService.loadSamples(from: audioURL)
            }
            session.duration = Double(samples.count) / AudioChunk.sampleRate
            let segments = try await timed(.asr, sessionID: sessionID, "Transcribe",
                                                    metadata: ["sampleCount": "\(samples.count)"]) {
                try await asrEngine.transcribe(samples: samples, track: .mixed, wordTimestamps: true)
            }

            job.advance(to: 2, stageText: "Saving…", progress: 0.9)
            try await persist(session: session, segments: segments, sessionID: sessionID)

            job.advance(to: 3, stageText: "Cleaning up…", progress: 0.98)
            await timed(.system, sessionID: sessionID, "Cleanup temp files") {
                await downloader.cleanup(jobID: sessionID)
            }

            job.finish(resultSessionID: sessionID)
            return sessionID
        } catch {
            await downloader.cleanup(jobID: sessionID)
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .download, level: .error,
                                          message: "URL job failed",
                                          metadata: ["error": String(describing: type(of: error))]))
            job.fail(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Persistence

    private func persist(session: TranscriptSession, segments: [AsrSegment], sessionID: UUID) async throws {
        try await timed(.persistence, sessionID: sessionID, "Save session",
                                metadata: ["segments": "\(segments.count)"]) {
            let attributed = segments.map {
                AttributedSegment(asr: $0, speaker: .unknown, speakerConfidence: 0, isProvisional: false)
            }
            session.fullText = segments.map(\.text).joined(separator: " ")
            session.status = .complete
            session.segments = attributed.map { StoredSegment(from: $0) }
            modelContext.insert(session)
            try modelContext.save()
        }
    }
}
