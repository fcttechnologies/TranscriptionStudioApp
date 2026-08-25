import Foundation
import Testing
@testable import TranscriptionStudio

/// The pure tracking logic behind the long-running `TranscribeFileIntent`/`TranscribeLinkIntent`:
/// following a `TranscriptionJob` to its terminal state, mirroring progress, and translating that
/// terminal state into an intent result (session id / thrown failure / cancellation). The
/// Siri/Shortcuts/Live-Activity plumbing around it is a runtime concern; the state translation is
/// not, and it's what a wrong fix would silently break.
@MainActor
struct TranscribeJobTrackingTests {
    private func job() -> TranscriptionJob {
        TranscriptionJob(title: "Meeting", steps: ["Ingest", "Transcribe", "Done"])
    }

    @Test func doneJobReturnsSessionIDAndCompletesProgress() async throws {
        let sessionID = UUID()
        let job = job()
        job.finish(resultSessionID: sessionID)

        let progress = Progress()
        let result = try await TranscribeJobTracking.awaitCompletion(of: job, reporting: progress)

        #expect(result == sessionID)
        #expect(progress.totalUnitCount == 100)
        #expect(progress.completedUnitCount == 100)   // finish() drives the job to progress 1.0
    }

    @Test func failedJobThrowsFailureCarryingItsMessage() async {
        let job = job()
        job.fail("The file could not be read.")

        await #expect(throws: TranscriptionJobFailure.self) {
            _ = try await TranscribeJobTracking.awaitCompletion(of: job, reporting: Progress())
        }

        do {
            _ = try await TranscribeJobTracking.awaitCompletion(of: job, reporting: Progress())
            Issue.record("Expected a failure")
        } catch let failure as TranscriptionJobFailure {
            #expect(failure.message == "The file could not be read.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancelledJobThrowsCancellation() async {
        let job = job()
        job.cancel()   // no running task in the test; sets state to .cancelled

        await #expect(throws: CancellationError.self) {
            _ = try await TranscribeJobTracking.awaitCompletion(of: job, reporting: Progress())
        }
    }

    @Test func midProgressIsMirroredBeforeCompletion() async throws {
        // A running job that then finishes: the loop mirrors the running stage/percentage into the
        // reported Progress, and returns once terminal.
        let sessionID = UUID()
        let job = job()
        job.advance(to: 1, stageText: "Transcribing", progress: 0.4)

        let progress = Progress()
        let tracker = Task { try await TranscribeJobTracking.awaitCompletion(of: job, reporting: progress) }

        // Wait for the loop to observe the running state at least once (poll rather than assume a
        // fixed delay, so the assertion is deterministic under load) — then complete the job.
        for _ in 0..<200 where progress.localizedAdditionalDescription != "Transcribing" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(progress.localizedAdditionalDescription == "Transcribing")
        #expect(progress.completedUnitCount == 40)   // 0.4 of 100, mirrored while running
        job.finish(resultSessionID: sessionID)

        #expect(try await tracker.value == sessionID)
    }
}
