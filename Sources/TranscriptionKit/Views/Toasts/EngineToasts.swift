import Foundation

// The app's wired toast classes: speech-model warmup progress and the shell's
// human-sentence failures (a denied mic, a failed import, a run-ending recording error).
// The prewarm mapping lives here — pure state-transition logic, tested directly.

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
            showOrUpdate(Toast(title: phase,
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
                show(Toast(title: "Speech model ready", systemImage: "checkmark",
                           style: .success, duration: .seconds(2.5),
                           dedupKey: "engine-ready"))
            }
        case .failed(let message):
            dismiss(dedupKey: Self.prewarmKey)
            show(Toast(title: "Couldn't prepare the speech model", message: message,
                       systemImage: "exclamationmark.triangle", style: .error,
                       duration: .seconds(6), dedupKey: "engine-failed"))
        }
    }
}

public extension Toast {
    /// Microphone access is denied — recording can't start. Tap-through to the app's
    /// Settings sheet (whose Permissions section deep-links onward to the system pane).
    static func microphoneDenied(openSettings: @MainActor @escaping () -> Void) -> Toast {
        Toast(title: "Microphone access is off",
              message: "Recording needs the microphone.",
              systemImage: "mic.slash", style: .warning,
              actionLabel: "Settings", action: openSettings,
              duration: .seconds(6), dedupKey: "mic-denied")
    }

    /// Screen Recording isn't granted — meeting capture can't start (macOS).
    static func screenRecordingNeeded(message: String,
                                      openSettings: @MainActor @escaping () -> Void) -> Toast {
        Toast(title: "Screen Recording is off",
              message: message,
              systemImage: "rectangle.dashed.badge.record", style: .warning,
              actionLabel: "Settings", action: openSettings,
              duration: .seconds(6), dedupKey: "screen-recording")
    }

    /// A run-ending recording failure, surfaced as a sentence (replaces the old alert).
    static func recordingFailed(_ message: String) -> Toast {
        Toast(title: "Couldn't record", message: message,
              systemImage: "exclamationmark.triangle", style: .error,
              duration: .seconds(6), dedupKey: "recording-failed")
    }

    /// A Photos/file import that couldn't produce a transcodable video.
    static func importFailed(_ message: String) -> Toast {
        Toast(title: "Couldn't import", message: message,
              systemImage: "exclamationmark.triangle", style: .error,
              duration: .seconds(6), dedupKey: "import-failed")
    }
}
