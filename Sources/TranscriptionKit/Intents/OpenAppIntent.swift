import AppIntents

/// The system-provided "open the app" action other intents hand back via
/// `.result(opensIntent:)` once they've set the router/model state the app should land on —
/// the replacement for the deprecated `openAppWhenRun`.
public struct OpenAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Transcription Studio"
    public static let supportedModes: IntentModes = .foreground

    public init() {}

    public func perform() async throws -> some IntentResult { .result() }
}
