import AppIntents

/// Open Settings. A `perform()` isn't a View, so it can't reach macOS's
/// `@Environment(\.openSettings)` directly — instead this sets the same router-flag pattern the
/// other navigating intents use (`appModel.selectedSurface`, `selectedSessionID`):
/// `AppModel.pendingSettingsRequest`, which iOS's Library gear-button sheet and macOS's
/// `MacRootView` each observe to open Settings on their platform.
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
