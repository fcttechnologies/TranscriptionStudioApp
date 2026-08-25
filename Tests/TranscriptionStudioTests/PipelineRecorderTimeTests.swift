// `PipelineRecorder.time(_:)` — the async-timing convenience wrapper every real pipeline
// stage uses to close a `PipelineEvent` with its duration attached. Every other test that
// touches `PipelineRecorder` calls `record(_:)` directly; nothing exercised `time` itself.
//
// Deliberately NOT `@MainActor`: `time`'s `operation` closure must stay isolation-free so it
// can run off the main actor (as production callers do); only `InspectorStore` itself — the
// thing `time` reports to — is main-actor-bound, so those touches hop over explicitly.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("PipelineRecorder.time")
struct PipelineRecorderTimeTests {
    @Test func returnsTheOperationsValueAndRecordsAClosingEventWithDuration() async throws {
        let store = await MainActor.run { InspectorStore() }
        let recorder = PipelineRecorder(store: store)
        let sessionID = UUID()

        let result = await recorder.time(.mel, sessionID: sessionID, "mel frontend",
                                         metadata: ["frames": "10"]) {
            42
        }
        #expect(result == 42)

        // `PipelineRecorder.record` forwards to the store via a detached `Task { @MainActor
        // in }` — give the MainActor queue a couple turns to drain it before asserting.
        await Task.yield()
        await Task.yield()
        let event = await MainActor.run { store.events.last }
        let unwrapped = try #require(event)
        #expect(unwrapped.stage == .mel)
        #expect(unwrapped.sessionID == sessionID)
        #expect(unwrapped.message == "mel frontend")
        #expect(unwrapped.metadata["frames"] == "10")
        #expect((unwrapped.duration ?? -1) >= 0)
    }

    @Test func rethrowsTheOperationsErrorWithoutRecordingAnEvent() async {
        struct Boom: Error {}
        let store = await MainActor.run { InspectorStore() }
        let recorder = PipelineRecorder(store: store)

        await #expect(throws: Boom.self) {
            _ = try await recorder.time(.asr, "asr window") {
                throw Boom()
            }
        }
        let isEmpty = await MainActor.run { store.events.isEmpty }
        #expect(isEmpty)
    }
}
