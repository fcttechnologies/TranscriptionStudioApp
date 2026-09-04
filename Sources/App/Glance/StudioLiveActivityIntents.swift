#if os(iOS)
import AppIntents
import FCTMetrics
import Foundation

// The Live Activity buttons' intents. `LiveActivityIntent` runs `perform()` in the app's
// process, so these trampoline through `StudioActivityActions` — registered by the app model at
// launch — and carry no dependencies of their own (the widget extension compiles this module).
// All are `isDiscoverable = false`: they exist for the activity's buttons, not the Shortcuts
// gallery (the app's real Siri surface lives in TranscriptionKit's intents).

/// Stop the live recording from its Live Activity.
struct StopRecordingActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        func run() async throws -> some IntentResult {
            await StudioActivityActions.stopRecording?()
            return .result()
        }
        return try await Diag.intent(TranscriptionCrumb.stopRecordingActivityIntent, run)
    }
}

/// Pause or resume the live recording from its Live Activity.
struct ToggleRecordingPauseActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        func run() async throws -> some IntentResult {
            StudioActivityActions.toggleRecordingPause?()
            return .result()
        }
        return try await Diag.intent(TranscriptionCrumb.toggleRecordingPauseActivityIntent, run)
    }
}

/// Play or pause the session's audio from its Live Activity.
struct TogglePlaybackActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        func run() async throws -> some IntentResult {
            StudioActivityActions.togglePlayback?()
            return .result()
        }
        return try await Diag.intent(TranscriptionCrumb.togglePlaybackActivityIntent, run)
    }
}
#endif
