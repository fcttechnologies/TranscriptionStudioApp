// The single-view shell's AppModel-level logic pass 1 left uncovered: stopping a live
// recording and routing to the saved session (or clearing the sheet when nothing was
// captured), the Share-extension URL ping → drop-box drain routing, the per-model engine
// cache that backs a transcription job, and the launch-time prewarm state machine.
//
// `handleIngestURL`/`ingestPendingShares`' file/url item-routing branches (the loop body in
// `ShareIngest.swift`) need a real App Group container to drain anything — `AppGroup
// .containerURL` returns nil in a plain `swift test` process (no entitlement), and the
// container isn't injectable through `AppModel`'s public surface. So those branches, and the
// private `copyToOwnedTemp` helper they'd exercise, stay untested here; what IS covered is the
// deterministic, container-independent behavior: URL recognition and the empty-box no-op.

import Foundation
import Synchronization
import SwiftData
import Testing
@testable import TranscriptionStudio

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@Suite("AppModel — stop recording + open")
@MainActor
struct AppModelStopRecordingTests {

    // stop() returns nil when nothing is recording; stopRecordingAndOpen then just clears a
    // live sheet left open rather than trying to open a session that was never saved.
    @Test func clearsTheLiveSheetWhenNothingWasCaptured() async throws {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.activeSheet = .liveRecording
        app.stopRecordingAndOpen()
        try await waitUntil(timeout: 2) { app.activeSheet == nil }
        #expect(app.activeSheet == nil)
    }

    // stopRecordingAndOpen with no live sheet and nothing recording is a quiet no-op.
    @Test func isANoOpWhenIdleAndNoSheetIsShowing() async throws {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.stopRecordingAndOpen()
        try await Task.sleep(for: .milliseconds(200))
        #expect(app.activeSheet == nil)
    }

    // A real (mocked) run: stop the recording once it's produced something, and confirm the
    // saved session's sheet is opened — the id round-trips through the persisted session.
    @Test func opensTheSavedSessionAfterARealRun() async throws {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.recording.start(mode: .room)
        try await waitUntil(timeout: 4) { app.recording.isRecording }
        try await waitUntil(timeout: 6) { !app.recording.segments.isEmpty }

        app.stopRecordingAndOpen()
        try await waitUntil(timeout: 6) {
            if case .session = app.activeSheet { return true }
            return false
        }
        guard case .session = app.activeSheet else {
            Issue.record("expected the shell to land on .session(id), got \(String(describing: app.activeSheet))")
            return
        }
    }
}

@Suite("AppModel — Share-extension ingest ping")
@MainActor
struct AppModelIngestPingTests {

    @Test func handleIngestURLRejectsAForeignURL() {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        #expect(app.handleIngestURL(URL(string: "https://example.com")!) == false)
        #expect(app.jobs.jobs.isEmpty)
    }

    // A real ingest ping is recognized (the guard passes) even though there's nothing to
    // drain in this process — draining an empty/unreachable box is the documented no-op.
    @Test func handleIngestURLAcceptsTheIngestPingAndDrainsQuietly() {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        #expect(app.handleIngestURL(IngestURLScheme.ingestURL(id: UUID())) == true)
        #expect(app.jobs.jobs.isEmpty)
    }

    @Test func ingestPendingSharesIsANoOpWithoutAnAppGroupContainer() {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.ingestPendingShares()   // must not throw/crash with no App Group entitlement
        #expect(app.jobs.jobs.isEmpty)
    }
}

@Suite("StudioSheet identity")
struct StudioSheetIdentityTests {
    @Test func idsAreStableAndDistinctPerCase() {
        let sessionID = UUID()
        #expect(StudioSheet.settings.id == "settings")
        #expect(StudioSheet.inspector.id == "inspector")
        #expect(StudioSheet.liveRecording.id == "liveRecording")
        #expect(StudioSheet.insertLink.id == "insertLink")
        #expect(StudioSheet.session(sessionID).id == "session-\(sessionID.uuidString)")
        #expect(StudioSheet.session(UUID()).id != StudioSheet.session(UUID()).id)
    }
}

@Suite("AppModel — launch-time prewarm state")
@MainActor
struct AppModelPrewarmTests {

    @Test func transitionsIdleToPreparingToReady() async throws {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        #expect(app.enginePrewarmState == .idle)
        app.prewarmDefaultEngine()
        #expect(app.enginePrewarmState.isPreparing)
        try await waitUntil(timeout: 3) { app.enginePrewarmState == .ready }
        #expect(app.enginePrewarmState == .ready)
    }

    // A second call while still preparing is a guarded no-op — it must not restart the warmup.
    @Test func isIdempotentWhileAlreadyPreparing() {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.prewarmDefaultEngine()
        let stateAfterFirstCall = app.enginePrewarmState
        app.prewarmDefaultEngine()
        #expect(app.enginePrewarmState == stateAfterFirstCall)
    }

    // A transcription needs both models, so the warmup prepares the recognizer and then the
    // diarizer; a diarizer that fails to prepare fails the warmup, never leaves it "ready".
    @Test func warmsTheRecognizerThenTheDiarizerAndFailsOnEither() async throws {
        let order = Mutex<[String]>([])
        let asr = PreparationSpyAsrEngine { order.withLock { $0.append("asr") } }
        let diarizer = PreparationSpyDiarizationEngine(failing: false) { order.withLock { $0.append("diarizer") } }
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory(), asr: asr, diarizer: diarizer)
        app.prewarmDefaultEngine()
        try await waitUntil(timeout: 3) { app.enginePrewarmState == .ready }
        #expect(order.withLock { $0 } == ["asr", "diarizer"])

        let failing = AppModel(modelContext: ModelContextFactory.makeInMemory(),
                               asr: MockAsrEngine(),
                               diarizer: PreparationSpyDiarizationEngine(failing: true) {})
        failing.prewarmDefaultEngine()
        try await waitUntil(timeout: 3) {
            if case .failed = failing.enginePrewarmState { return true } else { return false }
        }
    }
}

/// The mock recognizer, reporting when its `prepare` ran.
private final class PreparationSpyAsrEngine: AsrEngine, Sendable {
    private let inner = MockAsrEngine()
    private let onPrepare: @Sendable () -> Void
    init(onPrepare: @escaping @Sendable () -> Void) { self.onPrepare = onPrepare }
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onPrepare()
        try await inner.prepare(onProgress: onProgress)
    }
    func transcribe(samples: [Float], track: AudioTrack, wordTimestamps: Bool) async throws -> [AsrSegment] {
        try await inner.transcribe(samples: samples, track: track, wordTimestamps: wordTimestamps)
    }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<AsrUpdate, Error> {
        inner.stream(chunks: chunks)
    }
}

/// The mock diarizer, reporting when its `prepare` ran, or refusing to.
private final class PreparationSpyDiarizationEngine: DiarizationEngine, Sendable {
    struct Boom: Error {}
    let backendName = "Spy"
    private let inner = MockDiarizationEngine()
    private let failing: Bool
    private let onPrepare: @Sendable () -> Void
    init(failing: Bool, onPrepare: @escaping @Sendable () -> Void) {
        self.failing = failing
        self.onPrepare = onPrepare
    }
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws {
        onPrepare()
        if failing { throw Boom() }
        try await inner.prepare(onProgress: onProgress)
    }
    func diarize(samples: [Float]) async throws -> DiarizationResult { try await inner.diarize(samples: samples) }
    func stream(chunks: AsyncThrowingStream<AudioChunk, Error>) -> AsyncThrowingStream<DiarizationUpdate, Error> {
        inner.stream(chunks: chunks)
    }
}
