import AppIntents
import FCTMetrics

/// Open Settings. A `perform()` isn't a View, so it routes through the same shell state the
/// floating controls use: `AppModel.activeSheet` — both platforms present Settings as a sheet
/// over the single-view home.
struct OpenSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Settings"
    static let description = IntentDescription("Open Transcription Studio's settings.")
    static let supportedModes: IntentModes = .foreground(.dynamic)

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        func run() async throws -> some IntentResult & OpensIntent {
            await MainActor.run { appModel.activeSheet = .settings }
            return .result(opensIntent: OpenAppIntent())
        }
        return try await Diag.intent(TranscriptionCrumb.openSettingsIntent, run)
    }
}
