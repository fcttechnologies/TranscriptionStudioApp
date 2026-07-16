#if os(iOS)
import AppIntents
import Foundation

// The Live Activity buttons' intents. `LiveActivityIntent` runs `perform()` in the app's
// process, so these trampoline through `StudioActivityActions` — registered by the app model at
// launch — and carry no dependencies of their own (the widget extension compiles this module).
// All are `isDiscoverable = false`: they exist for the activity's buttons, not the Shortcuts
// gallery (the app's real Siri surface lives in TranscriptionKit's intents).

/// Stop the live recording from its Live Activity.
public struct StopRecordingActivityIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Recording"
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        await StudioActivityActions.stopRecording?()
        return .result()
    }
}

/// Pause or resume the live recording from its Live Activity.
public struct ToggleRecordingPauseActivityIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or Resume Recording"
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        StudioActivityActions.toggleRecordingPause?()
        return .result()
    }
}

/// Play or pause the session's audio from its Live Activity.
public struct TogglePlaybackActivityIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Play or Pause"
    public static let isDiscoverable = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        StudioActivityActions.togglePlayback?()
        return .result()
    }
}
#endif
