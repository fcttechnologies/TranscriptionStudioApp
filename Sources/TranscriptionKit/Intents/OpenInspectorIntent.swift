import AppIntents

/// Open the Inspector. Mirrors `OpenSettingsIntent` — a `perform()` isn't a View, so it routes
/// through the same shell state the toolbar's Inspector button uses: `AppModel.activeSheet` —
/// both platforms present the Inspector as a sheet over the single-view home.
public struct OpenInspectorIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Inspector"
    public static let description = IntentDescription("Open Transcription Studio's diagnostics inspector.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent {
        await MainActor.run { appModel.activeSheet = .inspector }
        return .result(opensIntent: OpenAppIntent())
    }
}
