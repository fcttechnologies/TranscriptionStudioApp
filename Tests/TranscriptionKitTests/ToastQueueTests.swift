// The ToastCenter/EngineToasts/Toast behaviors pass 1 left uncovered: the action-tap path,
// interaction-pause/resume around auto-dismiss, the queue's backlog cap, a stale-id dismiss
// being ignored, the prewarm→toast mapping's `.idle` case (a model switch resetting the
// state), and the app's wired toast builders.
// (BackgroundExecution's bridge + macOS passthrough live in BackgroundExecutionTests.swift.)

import Foundation
import Testing
@testable import TranscriptionKit

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@Suite("ToastCenter — action, interaction pause, queue cap")
@MainActor
struct ToastCenterInteractionTests {

    @Test func runActionDismissesAndInvokesTheClosure() {
        let center = ToastCenter()
        var invoked = false
        let toast = Toast(title: "Tap me", systemImage: "circle",
                          actionLabel: "Go", action: { invoked = true })
        center.show(toast)
        center.runAction(for: toast)
        #expect(invoked)
        #expect(center.current == nil)
    }

    // An informational toast (no action) is a safe no-op to run.
    @Test func runActionOnAnInformationalToastJustDismisses() {
        let center = ToastCenter()
        let toast = Toast(title: "FYI", systemImage: "circle")
        center.show(toast)
        center.runAction(for: toast)
        #expect(center.current == nil)
    }

    @Test func dismissIgnoresAMismatchedID() {
        let center = ToastCenter()
        center.show(Toast(title: "A", systemImage: "circle"))
        center.dismiss(id: UUID())
        #expect(center.current?.title == "A")
    }

    // Suspending pauses the auto-dismiss timer for a timed toast; it must still be showing
    // well past its original duration while suspended.
    @Test func suspendPausesAutoDismissPastItsOriginalDuration() async throws {
        let center = ToastCenter()
        let toast = Toast(title: "Timed", systemImage: "circle", duration: .milliseconds(150))
        center.show(toast)
        center.suspendAutoDismiss(for: toast.id)
        try await Task.sleep(for: .milliseconds(800))
        #expect(center.current?.id == toast.id)
    }

    // Resuming reschedules the dismiss after a short dwell rather than never again.
    @Test func resumeSchedulesADismissAfterTheDwell() async throws {
        let center = ToastCenter()
        let toast = Toast(title: "Timed", systemImage: "circle", duration: nil)   // sticky
        center.show(toast)
        center.suspendAutoDismiss(for: toast.id)
        center.resumeAutoDismiss(for: toast.id)
        #expect(center.current?.id == toast.id)   // not yet — the dwell hasn't elapsed
        // The dwell is a fixed 2s in production; wait comfortably past it (with margin for a
        // busy full-suite run) rather than trimming this to a hair-trigger timeout.
        try await waitUntil(timeout: 6) { center.current == nil }
        #expect(center.current == nil)
    }

    // suspend/resume targeting a stale id (not the one currently showing) are no-ops.
    @Test func suspendAndResumeIgnoreAStaleID() {
        let center = ToastCenter()
        center.show(Toast(title: "A", systemImage: "circle", duration: .seconds(5)))
        let staleID = UUID()
        center.suspendAutoDismiss(for: staleID)
        center.resumeAutoDismiss(for: staleID)
        #expect(center.current?.title == "A")
    }

    // The queue caps its backlog at 4: pushing a 5th behind an already-full queue drops the
    // oldest queued entry rather than growing unbounded.
    @Test func queueDropsTheOldestQueuedEntryPastTheCap() async throws {
        let center = ToastCenter()
        center.show(Toast(title: "0", systemImage: "circle"))
        for index in 1...5 {
            center.show(Toast(title: "\(index)", systemImage: "circle"))
        }
        var seen: [String] = [try #require(center.current?.title)]
        for _ in 0..<4 {
            let previous = center.current?.title
            center.dismiss()
            try await waitUntil(timeout: 3) { center.current != nil && center.current?.title != previous }
            seen.append(try #require(center.current?.title))
        }
        // "1" was dropped to make room for "5" once the queue hit its 4-deep cap.
        #expect(seen == ["0", "2", "3", "4", "5"])
        center.dismiss()
        try await waitUntil(timeout: 3) { center.current == nil }
        #expect(center.current == nil)
    }
}

@Suite("EngineToasts — the .idle mapping")
@MainActor
struct EngineToastsIdleTests {
    // A model switch resets `enginePrewarmState` to `.idle`; the toast layer resolves any
    // lingering progress notice rather than leaving it stuck on screen.
    @Test func idleDismissesALingeringProgressNotice() {
        let center = ToastCenter()
        center.handlePrewarm(from: .idle, to: .preparing(phase: "Preparing…", fraction: nil))
        #expect(center.current != nil)
        center.handlePrewarm(from: .preparing(phase: "Preparing…", fraction: nil), to: .idle)
        #expect(center.current == nil)
    }

    // Idle → idle (nothing was ever shown) is a quiet no-op.
    @Test func idleToIdleIsAQuietNoOp() {
        let center = ToastCenter()
        center.handlePrewarm(from: .idle, to: .idle)
        #expect(center.current == nil)
    }
}

@Suite("Toast — the app's wired builders")
@MainActor
struct ToastBuildersTests {
    @Test func microphoneDeniedCarriesATapThroughToSettings() {
        var tapped = false
        let toast = Toast.microphoneDenied { tapped = true }
        #expect(toast.style == .warning)
        #expect(toast.dedupKey == "mic-denied")
        #expect(toast.actionLabel == "Settings")
        toast.action?()
        #expect(tapped)
    }

    @Test func screenRecordingNeededCarriesATapThroughToSettings() {
        var tapped = false
        let toast = Toast.screenRecordingNeeded { tapped = true }
        #expect(toast.style == .warning)
        #expect(toast.dedupKey == "screen-recording")
        toast.action?()
        #expect(tapped)
    }

    @Test func screenRecordingNeedsRestartIsInformationalWithNoAction() {
        let toast = Toast.screenRecordingNeedsRestart()
        #expect(toast.style == .warning)
        #expect(toast.dedupKey == "screen-recording-restart")
        #expect(toast.action == nil)
    }

    @Test func recordingFailedCarriesTheMessageAsAnError() {
        let toast = Toast.recordingFailed("mic disconnected")
        #expect(toast.style == .error)
        #expect(toast.message == "mic disconnected")
        #expect(toast.dedupKey == "recording-failed")
    }

    @Test func importFailedCarriesTheMessageAsAnError() {
        let toast = Toast.importFailed("unsupported container")
        #expect(toast.style == .error)
        #expect(toast.message == "unsupported container")
        #expect(toast.dedupKey == "import-failed")
    }
}
