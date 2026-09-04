import AppIntents
import FCTMetrics

/// Open the Inspector. Mirrors `OpenSettingsIntent` — a `perform()` isn't a View, so it routes
/// through the same shell state the toolbar's Inspector button uses: `AppModel.activeSheet` —
/// both platforms present the Inspector as a sheet over the single-view home.
struct OpenInspectorIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Inspector"
    static let description = IntentDescription("Open Transcription Studio's diagnostics inspector.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        func run() async throws -> some IntentResult & OpensIntent {
            await MainActor.run { appModel.activeSheet = .inspector }
            return .result(opensIntent: OpenAppIntent())
        }
        return try await Diag.intent(TranscriptionCrumb.openInspectorIntent, run)
    }
}
