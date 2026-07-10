import Foundation
import Testing
import SwiftData
@testable import TranscriptionKit

/// End-to-end verification that the recording loop is real: prepare → capture → ASR + diarization
/// → fusion → inspector → persisted session, entirely on the mock engines. Also covers the
/// lifecycle robustness the real engines depend on: the preparing phase, the graceful stop drain
/// (the final ASR pass must land), the non-streaming diarizer's full-buffer fallback, and a
/// capture failure surfacing an error and ending the run.
@Suite("Recording flow (mocks)")
@MainActor
struct RecordingFlowTests {

    private func makeController(context: ModelContext,
                               asr: any AsrEngine = MockAsrEngine(),
                               diarizer: any DiarizationEngine = MockDiarizationEngine(),
                               captureFactory: @escaping RecordingController.CaptureFactory =
                                   RecordingController.mockCaptureFactory,
                               drainTimeout: Duration = .seconds(60)) -> (RecordingController, InspectorStore) {
        let inspector = InspectorStore()
        let recorder = PipelineRecorder(store: inspector)
        let controller = RecordingController(
            asr: asr,
            diarizer: diarizer,
            recorder: recorder,
            inspector: inspector,
            loadSampler: SystemLoadSampler(store: inspector),
            modelContext: context,
            settings: AppSettings(),
            captureFactory: captureFactory,
            drainTimeout: drainTimeout)
        return (controller, inspector)
    }

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: AppModelContainer.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @Test func liveRunProducesTranscriptEventsAndPersistsSession() async throws {
        let context = try inMemoryContext()
        let (controller, inspector) = makeController(context: context)

        controller.start(mode: .room)
        // The run prepares the engines first, then goes live.
        try await waitUntil(timeout: 4) { controller.isRecording }
        #expect(controller.isRecording)

        // Wait for the mock stream to produce fused transcript segments.
        try await waitUntil(timeout: 6) { !controller.segments.isEmpty }
        #expect(!controller.segments.isEmpty)
        #expect(!inspector.events.isEmpty)
        #expect(controller.elapsed > 0)

        let sessionID = await controller.stop()
        #expect(sessionID != nil)
        #expect(!controller.isRecording)
        #expect(controller.phase == .idle)

        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(!(session.segments ?? []).isEmpty)
        #expect(session.kind == .roomRecording)
        #expect(session.audioFileName != nil)
        #expect(!session.fullText.isEmpty)

        // The archived audio file was actually written.
        let name = try #require(session.audioFileName)
        let url = try #require(AudioFileIO.url(forFileName: name))
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func meetingModeAttributesLocalUserAsMe() async throws {
        let context = try inMemoryContext()
        let (controller, _) = makeController(context: context)

        controller.start(mode: .meeting)
        try await waitUntil(timeout: 8) {
            controller.segments.contains { $0.speaker == .me }
        }
        #expect(controller.segments.contains { $0.speaker == .me })
        let id = await controller.stop()
        #expect(id != nil)
        if let name = (try? context.fetch(FetchDescriptor<TranscriptSession>()))?.first?.audioFileName,
           let url = AudioFileIO.url(forFileName: name) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The preparing phase is real: a run enters `.preparing` synchronously on start, reports
    /// model progress, and reaches `.recording` only after the engines are prepared.
    @Test func preparingPhaseReachesRecording() async throws {
        let context = try inMemoryContext()
        let (controller, _) = makeController(context: context)

        controller.start(mode: .room)
        // Immediately after start, the run is preparing — not yet recording.
        guard case .preparing = controller.phase else {
            Issue.record("expected .preparing right after start, got \(controller.phase)")
            return
        }
        #expect(!controller.isRecording)

        try await waitUntil(timeout: 4) { controller.isRecording }
        #expect(controller.phase == .recording)

        _ = await controller.stop()
        cleanupArchive(context)
    }

    /// The graceful stop awaits the ASR engine's final pass: an engine whose last decode is slow
    /// still lands its tail in the persisted transcript (a premature cancel would drop it).
    @Test func gracefulStopDrainsFinalAsrPass() async throws {
        let context = try inMemoryContext()
        let marker = "FINAL_TAIL_WORDS_LANDED"
        let asr = SlowFinalAsrEngine(finalText: marker, finalDelay: .milliseconds(700))
        let (controller, _) = makeController(context: context, asr: asr)

        controller.start(mode: .room)
        try await waitUntil(timeout: 4) { controller.isRecording }
        // Let a little audio flow so the source has chunks to finish.
        try await Task.sleep(for: .milliseconds(700))

        let id = await controller.stop()
        #expect(id != nil)
        #expect(controller.segments.contains { $0.asr.text.contains(marker) })

        let session = try #require(try context.fetch(FetchDescriptor<TranscriptSession>()).first)
        #expect(session.fullText.contains(marker))
        cleanupArchive(context)
    }

    /// A non-streaming diarizer (its `stream` throws; only `diarize(samples:)` works) is handled by
    /// buffering the diar track and running one full-buffer pass during finishing — the transcript
    /// is speaker-attributed at stop even though nothing streamed live.
    @Test func nonStreamingDiarizerFusesAtStop() async throws {
        let context = try inMemoryContext()
        let diarizer = NonStreamingMockDiarizer()
        let (controller, _) = makeController(context: context, diarizer: diarizer)

        controller.start(mode: .room)
        try await waitUntil(timeout: 4) { controller.isRecording }
        // Nothing streams live, so liveTurns stays empty during the run.
        try await waitUntil(timeout: 6) { !controller.segments.isEmpty }
        #expect(controller.liveTurns.isEmpty)

        let id = await controller.stop()
        #expect(id != nil)
        #expect(diarizer.diarizeCallCount == 1)
        // The full-buffer pass ran and fused: turns exist and segments carry a resolved speaker.
        #expect(!controller.liveTurns.isEmpty)
        #expect(controller.segments.contains { $0.speaker != .unknown })
        cleanupArchive(context)
    }

    /// A capture source that fails to start surfaces a human error and ends the run cleanly
    /// (back to idle), rather than leaving the UI looking live.
    @Test func captureFailureSetsLastErrorAndEndsRun() async throws {
        let context = try inMemoryContext()
        let (controller, _) = makeController(context: context, captureFactory: { _, _, _ in
            [RecordingController.CaptureInput(source: FailingCaptureSource(), tracks: [.mixed])]
        })

        controller.start(mode: .room)
        try await waitUntil(timeout: 5) { controller.lastError != nil && controller.phase == .idle }
        #expect(controller.lastError != nil)
        #expect(controller.phase == .idle)
        #expect(!controller.isRecording)
        cleanupArchive(context)
    }

    @Test func seedSampleSessionIsIdempotent() throws {
        let context = try inMemoryContext()
        DemoContent.seedSampleSession(into: context)
        let after = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(after.count == 1)
        let session = try #require(after.first)
        #expect((session.segments ?? []).count == 6)
        #expect(session.audioFileName != nil)
        if let name = session.audioFileName, let url = AudioFileIO.url(forFileName: name) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Helpers

    /// Poll a main-actor condition until it holds or the timeout elapses.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Remove any archived WAV a persisted session left behind.
    private func cleanupArchive(_ context: ModelContext) {
        guard let sessions = try? context.fetch(FetchDescriptor<TranscriptSession>()) else { return }
        for session in sessions {
            if let name = session.audioFileName, let url = AudioFileIO.url(forFileName: name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - Test engines / sources

private enum TestError: Error { case captureFailed, noStreaming }

/// An ASR engine whose streaming final pass is deliberately slow, so a test can prove the stop
/// path awaits it rather than cancelling and dropping the last words.
private final class SlowFinalAsrEngine: AsrEngine, @unchecked Sendable {
    let finalText: String
    let finalDelay: Duration

    init(finalText: String, finalDelay: Duration) {
        self.finalText = finalText
        self.finalDelay = finalDelay
    }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
    }

    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] { [] }

    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        let finalText = self.finalText
        let finalDelay = self.finalDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                var track: AudioTrack = .mixed
                var horizon: TimeInterval = 0
                do {
                    for try await chunk in chunks {
                        track = chunk.track
                        horizon = max(horizon, chunk.endTime)
                        continuation.yield(AsrUpdate(
                            confirmed: [],
                            unconfirmed: [AsrSegment(track: track, start: max(horizon - 1, 0),
                                                     end: horizon, text: "…", isConfirmed: false)]))
                    }
                    // The slow final decode — the tail a premature cancel would lose.
                    try await Task.sleep(for: finalDelay)
                    let tail = AsrSegment(track: track, start: horizon, end: horizon + 1,
                                          text: finalText, isConfirmed: true)
                    continuation.yield(AsrUpdate(confirmed: [tail], unconfirmed: []))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A full-clip diarizer: `stream` is unsupported (throws), only `diarize(samples:)` works — the
/// SpeakerKit shape. The controller must buffer and run one full-buffer pass at stop.
private final class NonStreamingMockDiarizer: DiarizationEngine, @unchecked Sendable {
    let backendName = "NonStreaming (test)"
    var supportsStreaming: Bool { false }

    private let lock = NSLock()
    private var _diarizeCallCount = 0
    var diarizeCallCount: Int { lock.withLock { _diarizeCallCount } }

    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onProgress(EnginePreparationProgress(phase: "Ready", fraction: 1))
    }

    func diarize(samples: [Float]) async throws -> DiarizationResult {
        lock.withLock { _diarizeCallCount += 1 }
        let duration = max(Double(samples.count) / AudioChunk.sampleRate, 1)
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: duration, confidence: 0.9, isCommitted: true)]
        let frameCount = max(Int(duration / 0.08), 1)
        let activities = [[Float]](repeating: [0.9, 0, 0, 0], count: frameCount)
        return DiarizationResult(turns: turns,
                                 frames: SpeakerFrameMatrix(activities: activities, committedFrameCount: frameCount))
    }

    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { $0.finish(throwing: TestError.noStreaming) }
    }
}

/// A capture source whose `start()` fails immediately (mic denied / SCK error shape).
private final class FailingCaptureSource: CaptureSource, @unchecked Sendable {
    let chunks: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation

    init() { (chunks, continuation) = AsyncThrowingStream.makeStream() }

    func start() async throws { throw TestError.captureFailed }
    func stop() async { continuation.finish() }
}
