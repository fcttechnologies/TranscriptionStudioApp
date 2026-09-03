import AppIntents
import Foundation

/// The app-process trampoline a dictation control fires through, in the shape the Live Activity
/// buttons already use: the app registers what the action does, the intent calls it.
///
/// It exists because this file compiles into the widget extension as well as the app, so it can
/// name nothing the extension does not also carry. In the extension's own process the closure is
/// nil and calling it does nothing — which is correct, because `.foreground` means this intent
/// never performs there.
@MainActor
enum StudioDictationActions {
    /// Present the dictation surface and start recording. Set by the app model at launch.
    static var beginDictation: (() -> Void)?
}

/// "Dictate" from Control Center, the Lock Screen or the Action button.
///
/// **A control's `perform()` must return before the system re-queries the control's state**, so
/// this one only opens the app and hands off. The recording itself is the length of a person's
/// sentence and runs in the app process, driven by the surface this lands on — a control that
/// held the microphone open across that whole sentence would be a control that never returned.
struct OpenDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let description = IntentDescription(
        "Open Transcription Studio and start dictating. Your words come back as clean text.")
    /// Bring the app to the front — the recording and its Done button live there.
    static let supportedModes: IntentModes = .foreground

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        StudioDictationActions.beginDictation?()
        return .result()
    }
}
