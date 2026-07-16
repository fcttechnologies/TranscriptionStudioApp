import Foundation

/// The app-process hooks the Live Activity intents call. A Live Activity button's
/// `LiveActivityIntent` performs *in the app's process*, but its type must compile into the lean
/// widget extension — which can't link the app model. These closures bridge that: the app
/// registers its real handlers at launch (`AppModel` does it in its initializer), and the intents
/// below stay a dependency-free trampoline the extension can carry.
@MainActor
public enum StudioActivityActions {
    /// Stop the live recording and persist the session.
    public static var stopRecording: (@MainActor () async -> Void)?
    /// Pause/resume the live recording.
    public static var toggleRecordingPause: (@MainActor () -> Void)?
    /// Play/pause the loaded session's audio.
    public static var togglePlayback: (@MainActor () -> Void)?
}
