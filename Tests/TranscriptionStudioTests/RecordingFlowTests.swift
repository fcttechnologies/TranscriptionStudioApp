import Foundation
import Testing
import SwiftData
@testable import TranscriptionStudio

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
        #expect(!session.fullText.isEmpty)

        // The archived audio was stored as compressed data on the session row.
        let audioData = try #require(session.audioData)
        #expect(!audioData.isEmpty)
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
    }

    /// pause() halts the elapsed clock and marks isPaused; resume() picks the clock back up.
    /// A pause/resume with no recording underway (idle) or an already-paused/already-running
    /// call is a no-op guarded at the top of each method.
    @Test func pauseHaltsElapsedAndResumeContinuesIt() async throws {
        let context = try inMemoryContext()
        let (controller, _) = makeController(context: context)

        controller.start(mode: .room)
        try await waitUntil(timeout: 4) { controller.isRecording }

        controller.pause()
        #expect(controller.isPaused)
        let elapsedAtPause = controller.elapsed
        try await Task.sleep(for: .milliseconds(300))
        // Elapsed must not advance while paused.
        #expect(abs(controller.elapsed - elapsedAtPause) < 0.05)

        controller.resume()
        #expect(!controller.isPaused)
        try await waitUntil(timeout: 2) { controller.elapsed > elapsedAtPause + 0.05 }
        #expect(controller.elapsed > elapsedAtPause)

        _ = await controller.stop()
    }

    @Test func pauseAndResumeAreNoOpsOutsideTheirValidState() async throws {
        let context = try inMemoryContext()
        let (controller, _) = makeController(context: context)

        // Idle: neither call should crash or flip isPaused.
        controller.pause()
        #expect(!controller.isPaused)
        controller.resume()
        #expect(!controller.isPaused)

        controller.start(mode: .room)
        try await waitUntil(timeout: 4) { controller.isRecording }

        // resume() while not paused is a no-op.
        controller.resume()
        #expect(!controller.isPaused)

        controller.pause()
        #expect(controller.isPaused)
        // A second pause() while already paused is a no-op (doesn't double-accumulate elapsed).
        let elapsedAfterFirstPause = controller.elapsed
        controller.pause()
        #expect(abs(controller.elapsed - elapsedAfterFirstPause) < 0.05)

        controller.resume()
        _ = await controller.stop()
    }

    /// A drain that doesn't finish inside `drainTimeout` hits the timeout branch: the run
    /// still reaches `.idle` (the engine tasks are force-cancelled rather than awaited forever).
    @Test func stopForceCancelsAfterDrainTimeoutElapses() async throws {
        let context = try inMemoryContext()
        // A final ASR pass far slower than the drain timeout forces the timeout branch.
        let asr = SlowFinalAsrEngine(finalText: "too slow", finalDelay: .seconds(5))
        let (controller, inspector) = makeController(context: context, asr: asr,
                                                     drainTimeout: .milliseconds(200))

        controller.start(mode: .room)
        try await waitUntil(timeout: 4) { controller.isRecording }
        try await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        let id = await controller.stop()
        let elapsed = start.duration(to: .now)

        // The timeout branch returns promptly rather than blocking for the full 5s delay.
        #expect(elapsed < .seconds(3))
        #expect(controller.phase == .idle)
        #expect(!controller.isRecording)
        // PipelineRecorder mirrors to the inspector via a hop to the main actor, so the append
        // can trail stop()'s return by a beat.
        try await waitUntil(timeout: 2) {
            inspector.events.contains { $0.message.contains("Finishing timed out") }
        }
        #expect(inspector.events.contains { $0.message.contains("Finishing timed out") })
        _ = id
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
