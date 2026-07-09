import Foundation
import SwiftData
import Testing
@testable import TranscriptionKit

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

    private func makeService(context: ModelContext) -> (TranscriptionService, PipelineRecorder, InspectorStore) {
        let store = InspectorStore()
        let recorder = PipelineRecorder(store: store)
        let service = TranscriptionService(asrEngine: MockAsrEngine(), modelContext: context, recorder: recorder)
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
}
