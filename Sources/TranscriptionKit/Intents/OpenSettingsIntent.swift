import AppIntents

/// Open Settings. Neither shell exposes a "navigate here" call an intent's `perform()` can
/// drive directly — it isn't a View, so it can't reach macOS's `@Environment(\.openSettings)`
/// — so this sets the same router-flag pattern the other navigating intents use
/// (`appModel.selectedSurface`, `selectedSessionID`): `AppModel.pendingSettingsRequest`, which
/// iOS's Library gear-button sheet observes to open Settings. See that flag's doc comment for
/// the macOS follow-up.
public struct OpenSettingsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Settings"
    public static let description = IntentDescription("Open Transcription Studio's settings.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent {
        await MainActor.run { appModel.pendingSettingsRequest = true }
        return .result(opensIntent: OpenAppIntent())
    }
}
