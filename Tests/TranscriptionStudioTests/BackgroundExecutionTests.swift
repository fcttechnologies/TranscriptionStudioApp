import Foundation
import Testing
@testable import TranscriptionStudio

/// The pure logic behind background-transcription cover: the `TranscriptionJob` → task `Progress`
/// bridge, and the macOS branch of `BackgroundExecution.run` (the iOS `BGContinuedProcessingTask`
/// path can only be exercised on-device — see Documentation/BACKGROUND-TRANSCRIPTION.md).
@Suite("Background execution bridge")
struct BackgroundExecutionBridgeTests {

    // A job fraction maps onto the task's 0…100 unit scale, clamped and rounded.
    @Test func fractionMapsToUnitCount() {
        #expect(JobProgressBridge.totalUnitCount == 100)
        #expect(JobProgressBridge.completedUnitCount(forFraction: 0) == 0)
        #expect(JobProgressBridge.completedUnitCount(forFraction: 1) == 100)
        #expect(JobProgressBridge.completedUnitCount(forFraction: 0.55) == 55)
        // Rounds to nearest whole percent.
        #expect(JobProgressBridge.completedUnitCount(forFraction: 0.554) == 55)
        #expect(JobProgressBridge.completedUnitCount(forFraction: 0.556) == 56)
    }

    // Out-of-range fractions clamp rather than overshoot the task's unit total.
    @Test func fractionClampsOutOfRange() {
        #expect(JobProgressBridge.completedUnitCount(forFraction: -0.5) == 0)
        #expect(JobProgressBridge.completedUnitCount(forFraction: 2.0) == 100)
    }

    // Only terminal states stop the progress mirror; queued/running keep it alive.
    @Test func terminalStatesDetected() {
        #expect(JobProgressBridge.isTerminal(.done))
        #expect(JobProgressBridge.isTerminal(.error))
        #expect(JobProgressBridge.isTerminal(.cancelled))
        #expect(!JobProgressBridge.isTerminal(.queued))
        #expect(!JobProgressBridge.isTerminal(.running))
    }

    // The cross-platform entry runs the work to completion and wires it to `job.task`. On macOS
    // (this test host) that's the plain-Task passthrough branch; on iOS the same call routes
    // through the continued-processing coordinator.
    @Test @MainActor func runExecutesWorkAndWiresJobTask() async {
        let job = TranscriptionJob(title: "Bridge", steps: ["Only"])
        BackgroundExecution.run(job: job, title: "Bridge") {
            // Only reached if the work actually runs — proves the passthrough executes it.
            job.finish(resultSessionID: nil)
        }
        // Let the launched task run to completion via the wired job.task.
        await job.task?.value
        #expect(job.state == .done)
    }
}
