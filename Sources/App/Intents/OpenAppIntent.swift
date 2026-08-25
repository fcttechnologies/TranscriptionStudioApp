import AppIntents

/// The system-provided "open the app" action other intents hand back via
/// `.result(opensIntent:)` once they've set the router/model state the app should land on —
/// the replacement for the deprecated `openAppWhenRun`.
struct OpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Transcription Studio"
    static let supportedModes: IntentModes = .foreground

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}
