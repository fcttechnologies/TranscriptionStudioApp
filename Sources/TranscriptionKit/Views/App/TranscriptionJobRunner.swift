import Foundation
import SwiftData

/// Runs a file/URL transcription job against the engine contracts: walks the web-app step
/// trail (with live progress + pipeline events), transcribes and diarizes a buffer through
/// the injected engines, fuses, archives audio, and persists a real session. Mock-backed
/// today; the real ingest + WhisperKit engines drop in behind the same protocols.
@MainActor
struct TranscriptionJobRunner {
    let asr: any AsrEngine
    let diarizer: any DiarizationEngine
    let recorder: PipelineRecorder
    let inspector: InspectorStore
    let modelContext: ModelContext
    let settings: AppSettings

    func makeJob(title: String, source: TranscriptionSource) -> TranscriptionJob {
        let steps: [String]
        switch source {
        case .url: steps = ["Download", "Extract audio", "Transcribe", "Done"]
        case .file: steps = ["Import", "Transcribe", "Done"]
        }
        return TranscriptionJob(title: title, steps: steps)
    }

    func run(job: TranscriptionJob, source: TranscriptionSource) async {
        let sessionID = UUID()
        let duration: TimeInterval
        let kind: SessionKind
        let sourceURL: String?

        do {
            switch source {
            case .url(let string):
                kind = .urlTranscription
                sourceURL = string
                duration = 42
                try await step(job, index: 0, text: "Downloading media…", progress: 0.15,
                               stage: .download, sessionID: sessionID, message: "Fetched media stream")
                try Task.checkCancellation()
                try await step(job, index: 1, text: "Extracting audio…", progress: 0.35,
                               stage: .extract, sessionID: sessionID, message: "Extracted 16 kHz mono")
            case .file(_, let durationHint):
                kind = .fileTranscription
                sourceURL = nil
                duration = max(durationHint, 8)
                try await step(job, index: 0, text: "Reading file…", progress: 0.2,
                               stage: .ingest, sessionID: sessionID, message: "Loaded + converted audio")
            }
            try Task.checkCancellation()

            // Transcribe + diarize the buffer through the contracts.
            let transcribeStep = kind == .urlTranscription ? 2 : 1
            job.advance(to: transcribeStep, stageText: "Transcribing…", progress: 0.6)
            let samples = [Float](repeating: 0, count: Int(duration * AudioChunk.sampleRate))

            let diarClock = ContinuousClock.now
            let diarization = try await diarizer.diarize(samples: samples)
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .diarizeCommit,
                                          message: "Diarized buffer",
                                          duration: seconds(ContinuousClock.now - diarClock),
                                          metadata: ["turns": "\(diarization.turns.count)"]))
            inspector.setSpeakerFrames(diarization.frames, for: sessionID)
            try Task.checkCancellation()

            let asrClock = ContinuousClock.now
            let asrSegments = try await asr.transcribe(samples: samples, track: .mixed,
                                                       wordTimestamps: settings.wordTimestamps)
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .asr, message: "Transcribed buffer",
                                          duration: seconds(ContinuousClock.now - asrClock),
                                          metadata: ["model": settings.whisperModel.rawValue,
                                                     "segments": "\(asrSegments.count)"]))

            job.advance(to: transcribeStep, stageText: "Attributing speakers…", progress: 0.85)
            let fused = TranscriptFuser.attribute(asr: asrSegments, turns: diarization.turns)
            recorder.record(PipelineEvent(sessionID: sessionID, stage: .fusion,
                                          message: "Fused transcript",
                                          metadata: ["segments": "\(fused.count)"]))

            let id = persist(sessionID: sessionID, title: job.title, kind: kind,
                             sourceURL: sourceURL, duration: duration,
                             turns: diarization.turns, segments: fused)
            job.finish(resultSessionID: id)
        } catch is CancellationError {
            // The job was cancelled by the user; its state is already `.cancelled`.
        } catch {
            job.fail("Couldn't finish transcribing. \(error.localizedDescription)")
        }
    }

    private func step(_ job: TranscriptionJob, index: Int, text: String, progress: Double,
                      stage: PipelineStage, sessionID: UUID, message: String) async throws {
        job.advance(to: index, stageText: text, progress: progress)
        try await Task.sleep(for: .milliseconds(650))
        recorder.record(PipelineEvent(sessionID: sessionID, stage: stage, message: message,
                                      duration: 0.65))
    }

    private func persist(sessionID: UUID, title: String, kind: SessionKind, sourceURL: String?,
                         duration: TimeInterval, turns: [SpeakerTurn],
                         segments: [AttributedSegment]) -> UUID {
        let session = TranscriptSession(title: title, kind: kind)
        session.id = sessionID
        session.status = .complete
        session.duration = duration
        session.sourceURLString = sourceURL
        session.fullText = segments.map(\.asr.text).joined(separator: " ")

        let fileName = "\(sessionID.uuidString).wav"
        let samples = AudioFileIO.synthesize(turns: turns.map { ($0.start, $0.end, $0.speakerIndex) },
                                             totalDuration: duration)
        if let saved = try? AudioFileIO.writeWAV(samples: samples, fileName: fileName) {
            session.audioFileName = saved
        }
        for attributed in segments {
            let stored = StoredSegment(from: attributed)
            stored.session = session
            session.segments?.append(stored)
        }
        modelContext.insert(session)
        recorder.record(PipelineEvent(sessionID: sessionID, stage: .persistence, message: "Session saved"))
        try? modelContext.save()
        TranscriptSpotlightIndex.index(session)
        return sessionID
    }
}
