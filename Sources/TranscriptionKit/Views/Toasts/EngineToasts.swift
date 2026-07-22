import Foundation
import FCTComponentsUI

// The app's wired toast classes: speech-model warmup progress and the shell's
// human-sentence failures (a denied mic, a failed import, a run-ending recording error).
// The prewarm mapping lives here — pure state-transition logic, tested directly.
//
// The queue, the card, and the overlay are the shared `FCTToast` layer in FCTComponentsUI
// (ported from this app's original `ToastCenter`); this file is only the domain layer that
// re-expresses that model over the app's status classes.

extension ToastCenter {
    static let prewarmKey = "engine-prewarm"

    /// Route an `EnginePrewarmState` transition into the toast layer: preparing shows (and
    /// updates in place) a sticky progress notice; ready/failed resolve it. Idempotent per
    /// transition — the home view calls this from `onChange`.
    public func handlePrewarm(from old: EnginePrewarmState, to new: EnginePrewarmState) {
        switch new {
        case .idle:
            dismiss(dedupKey: Self.prewarmKey)
        case .preparing(let phase, let fraction):
            showOrUpdate(FCTToast(title: phase,
                                  message: fraction.map { "\(Int($0 * 100))%" },
                                  systemImage: "waveform",
                                  isProgress: true,
                                  duration: nil,
                                  dedupKey: Self.prewarmKey))
        case .ready:
            dismiss(dedupKey: Self.prewarmKey)
            // Only announce readiness when the user actually saw a warmup — a mock/preview
            // model that's instantly ready shouldn't greet every launch with a toast.
            if case .preparing = old {
                show(FCTToast(title: "Speech model ready", systemImage: "checkmark",
                              style: .success, duration: .seconds(2.5),
                              dedupKey: "engine-ready"))
            }
        case .failed(let message):
            dismiss(dedupKey: Self.prewarmKey)
            show(FCTToast(title: "Couldn't prepare the speech model", message: message,
                          systemImage: "exclamationmark.triangle", style: .error,
                          duration: .seconds(6), dedupKey: "engine-failed"))
        }
    }
}

public extension FCTToast {
    /// Microphone access is denied — recording can't start. Tap-through to the app's
    /// Settings sheet (whose Permissions section deep-links onward to the system pane).
    static func microphoneDenied(openSettings: @MainActor @escaping () -> Void) -> FCTToast {
        FCTToast(title: "Microphone access is off",
                 message: "Recording needs the microphone.",
                 systemImage: "mic.slash", style: .warning,
                 actionLabel: "Settings", action: openSettings,
                 duration: .seconds(6), dedupKey: "mic-denied")
    }

    /// Screen Recording isn't granted — meeting capture can't start (macOS).
    static func screenRecordingNeeded(openSettings: @MainActor @escaping () -> Void) -> FCTToast {
        FCTToast(title: "Screen Recording is off",
                 message: "Meeting capture needs the Screen Recording permission.",
                 systemImage: "rectangle.dashed.badge.record", style: .warning,
                 actionLabel: "Settings", action: openSettings,
                 duration: .seconds(6), dedupKey: "screen-recording")
    }

    /// Screen Recording was just granted — macOS requires a relaunch before capture works.
    static func screenRecordingNeedsRestart() -> FCTToast {
        FCTToast(title: "Relaunch to finish enabling",
                 message: "Screen Recording is granted — quit and reopen, then start the meeting.",
                 systemImage: "arrow.clockwise.circle", style: .warning,
                 duration: .seconds(6), dedupKey: "screen-recording-restart")
    }

    /// A run-ending recording failure, surfaced as a sentence (replaces the old alert).
    static func recordingFailed(_ message: String) -> FCTToast {
        FCTToast(title: "Couldn't record", message: message,
                 systemImage: "exclamationmark.triangle", style: .error,
                 duration: .seconds(6), dedupKey: "recording-failed")
    }

    /// A Photos/file import that couldn't produce a transcodable video.
    static func importFailed(_ message: String) -> FCTToast {
        FCTToast(title: "Couldn't import", message: message,
                 systemImage: "exclamationmark.triangle", style: .error,
                 duration: .seconds(6), dedupKey: "import-failed")
    }
}
