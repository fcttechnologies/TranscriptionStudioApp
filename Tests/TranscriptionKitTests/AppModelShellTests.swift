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
import ShareKit
@testable import TranscriptionKit

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

@Suite("AppModel — per-model engine cache")
@MainActor
struct AppModelEngineCacheTests {

    // Two jobs against the same (default) model/backend must reuse the built engine rather
    // than asking the provider again — the cache keys by variant/backend, not by call count.
    @Test func sameModelReusesTheCachedEngineAcrossJobs() async throws {
        let asrCalls = Mutex<[String]>([])
        let diarCalls = Mutex<[String]>([])
        let inspector = InspectorStore()
        let recorder = PipelineRecorder(store: inspector)
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory(),
                           inspector: inspector,
                           recorder: recorder,
                           asr: MockAsrEngine(),
                           diarizer: MockDiarizationEngine(),
                           crossCheckDiarizer: PreviewAltDiarizer(),
                           captureFactory: RecordingController.mockCaptureFactory,
                           asrEngineProvider: { variant in
                               asrCalls.withLock { $0.append(variant) }
                               return MockAsrEngine()
                           },
                           diarizerProvider: { backend in
                               diarCalls.withLock { $0.append(backend.rawValue) }
                               return MockDiarizationEngine()
                           })

        // An unsupported extension fails FileIngestService synchronously — the two jobs
        // finish fast, so this only exercises the engine selection, never real transcription.
        let badFile = URL(fileURLWithPath: "/tmp/AppModelEngineCacheTests-\(UUID().uuidString).badext")

        app.startTranscription(title: "First", source: .file(badFile))
        let firstJob = try #require(app.jobs.jobs.last)
        try await waitUntil(timeout: 3) { firstJob.state == .error || firstJob.state == .done }

        app.startTranscription(title: "Second", source: .file(badFile))
        let secondJob = try #require(app.jobs.jobs.last)
        try await waitUntil(timeout: 3) { secondJob.state == .error || secondJob.state == .done }

        let expectedVariant = AppSettings.WhisperModel.platformDefault.whisperKitVariant
        let expectedBackend = AppSettings.DiarizerBackend.platformDefault.rawValue
        #expect(asrCalls.withLock { $0 } == [expectedVariant])
        #expect(diarCalls.withLock { $0 } == [expectedBackend])
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

    // Switching the selected model resets to idle and immediately re-enters preparing —
    // the force-rewarm path Settings uses after a model change.
    @Test func selectedModelChangeResetsThenRewarms() async throws {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        app.prewarmDefaultEngine()
        try await waitUntil(timeout: 3) { app.enginePrewarmState == .ready }

        app.prewarmSelectedModel()
        #expect(app.enginePrewarmState.isPreparing)
        try await waitUntil(timeout: 3) { app.enginePrewarmState == .ready }
        #expect(app.enginePrewarmState == .ready)
    }
}
