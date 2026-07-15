import Foundation
import Synchronization
import SwiftData
import Testing
@testable import TranscriptionKit

/// A diarizer that fails on demand, to prove the pipeline degrades gracefully (transcript
/// still produced, speakers unknown) rather than failing the whole job.
private final class FailingDiarizationEngine: DiarizationEngine, @unchecked Sendable {
    let backendName = "Failing"
    let failOnPrepare: Bool
    init(failOnPrepare: Bool) { self.failOnPrepare = failOnPrepare }

    struct Boom: Error {}

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        if failOnPrepare { throw Boom() }
    }
    func diarize(samples: [Float]) async throws -> DiarizationResult { throw Boom() }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Wraps `MockAsrEngine`, recording that `prepare` ran (with progress) and what
/// `wordTimestamps` value the job passed through to transcription.
private final class SpyAsrEngine: AsrEngine, @unchecked Sendable {
    private let inner = MockAsrEngine()
    let prepareProgressCount = Mutex(0)
    let wordTimestampsSeen = Mutex<Bool?>(nil)

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        try await inner.prepare { progress in
            self.prepareProgressCount.withLock { $0 += 1 }
            onProgress(progress)
        }
    }
    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        wordTimestampsSeen.withLock { $0 = wordTimestamps }
        return try await inner.transcribe(samples: samples, track: track, wordTimestamps: wordTimestamps)
    }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        inner.stream(chunks: chunks)
    }
}

/// A deterministic `URLAudioDownloading` fake — no subprocess, no network — so
/// `TranscriptionService`'s URL-job orchestration is exercisable in a plain unit test.
/// An actor so its mutable state (calls recorded, failure toggle) is race-free.
private actor MockURLDownloader: URLAudioDownloading {
    let fileToReturn: URL
    private(set) var cleanedUpJobIDs: [UUID] = []
    private(set) var shouldFail = false

    init(fileToReturn: URL) {
        self.fileToReturn = fileToReturn
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func downloadAudio(url: String, jobID: UUID,
                       onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        onProgress(DownloadProgress(fractionCompleted: 0.5, etaText: "00:01"))
        if shouldFail { throw URLIngestError.downloadFailed("mock failure") }
        onProgress(DownloadProgress(fractionCompleted: 1.0, etaText: nil))
        return fileToReturn
    }

    func cleanup(jobID: UUID) async {
        cleanedUpJobIDs.append(jobID)
    }
}

@Suite("TranscriptionService — job step progression")
@MainActor
struct TranscriptionServiceTests {

    // A real (tiny) wav file so FileIngestService can actually load samples without a
    // network or model dependency — MockAsrEngine stands in for WhisperKit.
    private static func makeTestWav() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        // Minimal valid 16-bit PCM mono WAV header + a moment of silence (0.2s @ 16kHz).
        let sampleRate: UInt32 = 16_000
        let sampleCount = 3_200
        var data = Data()
        func append32(_ v: UInt32) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func append16(_ v: UInt16) { data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        let byteRate = sampleRate * 2
        let dataSize = UInt32(sampleCount * 2)
        data.append(contentsOf: "RIFF".utf8); append32(36 + dataSize); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(byteRate); append16(2); append16(16)
        data.append(contentsOf: "data".utf8); append32(dataSize)
        data.append(Data(count: sampleCount * 2))
        try data.write(to: url)
        return url
    }

    private func makeService(context: ModelContext,
                             asr: any AsrEngine = MockAsrEngine(),
                             diarizer: any DiarizationEngine = MockDiarizationEngine(),
                             wordTimestamps: Bool = false)
        -> (TranscriptionService, PipelineRecorder, InspectorStore) {
        let store = InspectorStore()
        let recorder = PipelineRecorder(store: store)
        let service = TranscriptionService(asrEngine: asr, diarizer: diarizer, modelContext: context,
                                           recorder: recorder, inspector: store,
                                           wordTimestamps: wordTimestamps, modelName: "mock-model")
        return (service, recorder, store)
    }

    @Test func fileJobAdvancesThroughAllStepsAndFinishes() async throws {
        let wav = try Self.makeTestWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        let context = ModelContextFactory.makeInMemory()
        let (service, _, _) = makeService(context: context)
        let job = TranscriptionJob(title: "Test file", steps: TranscriptionService.fileJobSteps)

        let sessionID = await service.runFileJob(fileURL: wav, job: job)

        #expect(job.state == .done)
        #expect(job.progress == 1)
        #expect(job.activeStepIndex == TranscriptionService.fileJobSteps.count)
        let id = try #require(sessionID)
        #expect(job.resultSessionID == id)

        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].status == .complete)
        #expect(sessions[0].kind == .fileTranscription)
        #expect(!sessions[0].fullText.isEmpty)
        #expect((sessions[0].segments?.count ?? 0) > 0)
    }

    @Test func fileJobFailsCleanlyForUnsupportedExtension() async throws {
        let context = ModelContextFactory.makeInMemory()
        let (service, _, _) = makeService(context: context)
        let job = TranscriptionJob(title: "Bad file", steps: TranscriptionService.fileJobSteps)
        let badFile = URL(fileURLWithPath: "/tmp/not-real.exe")

        let sessionID = await service.runFileJob(fileURL: badFile, job: job)

        #expect(sessionID == nil)
        #expect(job.state == .error)
        #expect(job.errorMessage != nil)
        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.isEmpty)
    }

    @Test func urlJobAdvancesThroughAllStepsAndCleansUp() async throws {
        let wav = try Self.makeTestWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        let context = ModelContextFactory.makeInMemory()
        let (service, _, _) = makeService(context: context)
        let downloader = MockURLDownloader(fileToReturn: wav)
        let job = TranscriptionJob(title: "Test URL", steps: TranscriptionService.urlJobSteps)

        let sessionID = await service.runURLJob(urlString: "https://example.com/video", downloader: downloader, job: job)

        #expect(job.state == .done)
        #expect(job.activeStepIndex == TranscriptionService.urlJobSteps.count)
        let id = try #require(sessionID)
        #expect(await downloader.cleanedUpJobIDs == [id])

        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].kind == .urlTranscription)
        #expect(sessions[0].sourceURLString == "https://example.com/video")
    }

    @Test func urlJobFailureStillCleansUpTempAndFailsJob() async throws {
        let context = ModelContextFactory.makeInMemory()
        let (service, _, _) = makeService(context: context)
        let downloader = MockURLDownloader(fileToReturn: URL(fileURLWithPath: "/tmp/unused.wav"))
        await downloader.setShouldFail(true)
        let job = TranscriptionJob(title: "Failing URL", steps: TranscriptionService.urlJobSteps)

        let sessionID = await service.runURLJob(urlString: "https://example.com/video", downloader: downloader, job: job)

        #expect(sessionID == nil)
        #expect(job.state == .error)
        #expect(await downloader.cleanedUpJobIDs.count == 1)
        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.isEmpty)
    }

    // Every stage of a successful file job is recorded through the PipelineRecorder —
    // the app's #1 requirement: nothing runs unlogged.
    @Test func everyStageIsRecorded() async throws {
        let wav = try Self.makeTestWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        let context = ModelContextFactory.makeInMemory()
        let (service, _, store) = makeService(context: context)
        let job = TranscriptionJob(title: "Test file", steps: TranscriptionService.fileJobSteps)

        _ = await service.runFileJob(fileURL: wav, job: job)
        // `PipelineRecorder.record` forwards to the store via a detached `Task { @MainActor
        // in }` — give the MainActor queue a couple turns to drain those before asserting.
        await Task.yield()
        await Task.yield()

        let stages = Set(store.events.map(\.stage))
        #expect(stages.contains(.ingest))
        #expect(stages.contains(.asr))
        #expect(stages.contains(.persistence))
        #expect(store.events.allSatisfy { $0.duration == nil || $0.duration! >= 0 })
    }

    // The real runner path: model prep runs (progress surfaced), the diarizer runs and its
    // frames reach the inspector, fusion attributes a speaker, and the ingested audio is
    // archived to a WAV so the session is click-to-playable. Also proves a plain (non
    // security-scoped) URL ingests fine — startAccessingSecurityScopedResource returns
    // false and is handled gracefully.
    @Test func fileJobPreparesDiarizesFusesAndArchives() async throws {
        let wav = try Self.makeTestWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        let context = ModelContextFactory.makeInMemory()
        let spy = SpyAsrEngine()
        let (service, _, store) = makeService(context: context, asr: spy, wordTimestamps: true)
        let job = TranscriptionJob(title: "Real path", steps: TranscriptionService.fileJobSteps)

        let sessionID = try #require(await service.runFileJob(fileURL: wav, job: job))

        #expect(job.state == .done)
        // Prepare ran and reported progress; the job's chosen wordTimestamps flowed through.
        #expect(spy.prepareProgressCount.withLock { $0 } > 0)
        #expect(spy.wordTimestampsSeen.withLock { $0 } == true)

        // Diarizer frames reached the inspector, and fusion attributed at least one speaker.
        #expect(store.latestSpeakerFrames[sessionID] != nil)
        await Task.yield(); await Task.yield()
        let stages = Set(store.events.map(\.stage))
        #expect(stages.contains(.diarizeCommit))
        #expect(stages.contains(.fusion))

        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(session.audioData != nil)
        #expect((session.segments ?? []).contains { $0.speakerSlot >= 0 })
    }

    // A diarizer that can't prepare/diarize doesn't fail the job: a transcript is still
    // produced with speakers unknown, and the failure is recorded as a warning event.
    @Test func fileJobDegradesGracefullyWhenDiarizerFails() async throws {
        let wav = try Self.makeTestWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        let context = ModelContextFactory.makeInMemory()
        let (service, _, store) = makeService(context: context, diarizer: FailingDiarizationEngine(failOnPrepare: true))
        let job = TranscriptionJob(title: "No diarizer", steps: TranscriptionService.fileJobSteps)

        _ = try #require(await service.runFileJob(fileURL: wav, job: job))

        #expect(job.state == .done)
        await Task.yield(); await Task.yield()
        #expect(store.events.contains { $0.level == .warning && $0.stage == .diarizeCommit })

        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(!session.fullText.isEmpty)
        // No diarization coverage → every segment is unknown (speakerSlot == -2).
        #expect((session.segments ?? []).allSatisfy { $0.speakerSlot == -2 })
    }

    // A diarizer that prepares but throws during diarize also degrades gracefully.
    @Test func fileJobDegradesGracefullyWhenDiarizeThrows() async throws {
        let wav = try Self.makeTestWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        let context = ModelContextFactory.makeInMemory()
        let (service, _, store) = makeService(context: context, diarizer: FailingDiarizationEngine(failOnPrepare: false))
        let job = TranscriptionJob(title: "Diarize throws", steps: TranscriptionService.fileJobSteps)

        _ = try #require(await service.runFileJob(fileURL: wav, job: job))

        #expect(job.state == .done)
        await Task.yield(); await Task.yield()
        #expect(store.events.contains { $0.level == .warning && $0.stage == .diarizeCommit })
    }
}
