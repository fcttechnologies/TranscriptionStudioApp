import AppIntents

/// Open Settings. A `perform()` isn't a View, so it routes through the same shell state the
/// floating controls use: `AppModel.activeSheet` — both platforms present Settings as a sheet
/// over the single-view home.
public struct OpenSettingsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Settings"
    public static let description = IntentDescription("Open Transcription Studio's settings.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent {
        await MainActor.run { appModel.activeSheet = .settings }
        return .result(opensIntent: OpenAppIntent())
    }
}
