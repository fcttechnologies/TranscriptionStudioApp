import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("TranscriptionJob lifecycle")
@MainActor
struct TranscriptionJobTests {

    // A job walks queued → running → done with clamped progress.
    @Test func happyPath() {
        let job = TranscriptionJob(title: "Test", steps: ["Download", "Transcribe", "Done"])
        #expect(job.state == .queued)
        job.advance(to: 0, stageText: "Downloading…", progress: 0.4)
        #expect(job.state == .running)
        #expect(job.activeStepIndex == 0)
        job.advance(to: 1, stageText: "Transcribing…", progress: 0.8)
        job.finish(resultSessionID: UUID())
        #expect(job.state == .done)
        #expect(job.progress == 1)
        #expect(job.resultSessionID != nil)
    }

    // Failure captures the message; step index clamps to valid range.
    @Test func failureAndClamping() {
        let job = TranscriptionJob(title: "Test", steps: ["Only"])
        job.advance(to: 99, stageText: "Working…", progress: 2.0)
        #expect(job.activeStepIndex == 0)
        #expect(job.progress == 1)
        job.fail("Download failed: mock")
        #expect(job.state == .error)
        #expect(job.errorMessage == "Download failed: mock")
    }

    // The store sweeps terminal jobs past retention, keeps live ones regardless of age.
    @Test func sweepRespectsStateAndRetention() {
        let store = JobStore()
        store.retention = 10
        let old = TranscriptionJob(title: "Old done", steps: ["A"])
        old.finish(resultSessionID: nil)
        let live = TranscriptionJob(title: "Old running", steps: ["A"])
        live.advance(to: 0, stageText: "Working…", progress: 0.5)
        store.add(old)
        store.add(live)
        store.sweep(now: Date(timeIntervalSinceNow: 60))
        #expect(store.jobs.count == 1)
        #expect(store.jobs[0].title == "Old running")
    }

    // Deleting a session removes the finished job that produced it, but leaves a running job
    // (which has no resultSessionID yet) and an unrelated finished job untouched.
    @Test func removeJobsForSessionIDRemovesOnlyItsFinishedJob() {
        let store = JobStore()
        let sessionID = UUID()

        let finished = TranscriptionJob(title: "Finished", steps: ["A"])
        finished.finish(resultSessionID: sessionID)
        let otherFinished = TranscriptionJob(title: "Other finished", steps: ["A"])
        otherFinished.finish(resultSessionID: UUID())
        let running = TranscriptionJob(title: "Running", steps: ["A"])
        running.advance(to: 0, stageText: "Working…", progress: 0.5)

        store.add(finished)
        store.add(otherFinished)
        store.add(running)

        store.removeJobs(forSessionID: sessionID)

        #expect(store.jobs.map(\.title).sorted() == ["Other finished", "Running"])
    }
}

@Suite("InspectorStore")
@MainActor
struct InspectorStoreTests {

    // The event ring stays bounded at capacity, dropping oldest-first.
    @Test func ringBufferCaps() {
        let store = InspectorStore()
        for index in 0..<(InspectorStore.eventCapacity + 50) {
            store.append(PipelineEvent(stage: .asr, message: "event \(index)"))
        }
        #expect(store.events.count == InspectorStore.eventCapacity)
        #expect(store.events.first?.message == "event 50")
    }

    // latestDurations reports the most recent timed event per stage.
    @Test func latestDurationsPerStage() {
        let store = InspectorStore()
        store.append(PipelineEvent(stage: .asr, message: "window 1", duration: 0.5))
        store.append(PipelineEvent(stage: .asr, message: "window 2", duration: 0.7))
        store.append(PipelineEvent(stage: .mel, message: "chunk", duration: 0.02))
        let durations = store.latestDurations()
        #expect(durations[.asr] == 0.7)
        #expect(durations[.mel] == 0.02)
    }
}

@Suite("Persistence")
@MainActor
struct PersistenceTests {
    // The schema round-trips an attributed segment, including the speaker flattening.
    @Test func storedSegmentRoundTrip() throws {
        let context = ModelContextFactory.makeInMemory()
        let session = TranscriptSession(title: "Test", kind: .roomRecording)
        let attributed = AttributedSegment(
            asr: AsrSegment(track: .system, start: 1, end: 2, text: "hi",
                            avgLogprob: -0.2),
            speaker: .speaker(2), speakerConfidence: 0.85, isProvisional: false)
        let stored = StoredSegment(from: attributed)
        session.segments?.append(stored)
        context.insert(session)
        try context.save()

        #expect(stored.speaker == .speaker(2))
        stored.speaker = .me
        #expect(stored.speakerSlot == -1)
        stored.speaker = .unknown
        #expect(stored.speakerSlot == -2)
    }
}

import SwiftData

enum ModelContextFactory {
    @MainActor
    static func makeInMemory() -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: AppModelContainer.schema, configurations: [config])
        return ModelContext(container)
    }
}
