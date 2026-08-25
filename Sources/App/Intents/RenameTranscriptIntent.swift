import AppIntents
import SwiftData

/// Rename a saved transcript — mirrors the session detail view's title-bar Rename action.
/// Depends on the live `AppModel` for its SwiftData context, like `DeleteTranscriptIntent`.
struct RenameTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Transcript"
    static let description = IntentDescription("Rename a saved transcript in Transcription Studio.")
    static let supportedModes: IntentModes = .background
    static var parameterSummary: some ParameterSummary { Summary("Rename \(\.$target) to \(\.$newTitle)") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript would you like to rename?"))
    var target: TranscriptSessionEntity

    @Parameter(title: "New Title",
               requestValueDialog: IntentDialog("What would you like to rename it to?"))
    var newTitle: String

    @Dependency private var appModel: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = UUID(uuidString: target.id) else {
            throw RenameTranscriptIntentError.transcriptNotFound
        }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameTranscriptIntentError.emptyTitle }

        let context = appModel.modelContext
        let predicate = #Predicate<TranscriptSession> { $0.id == id }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let session = try context.fetch(descriptor).first else {
            throw RenameTranscriptIntentError.transcriptNotFound
        }

        session.title = trimmed
        try? context.save()
        TranscriptSpotlightIndex.index(session)
        return .result(dialog: "Renamed to \"\(trimmed)\".")
    }
}

enum RenameTranscriptIntentError: Error, CustomLocalizedStringResourceConvertible {
    case transcriptNotFound
    case emptyTitle

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .transcriptNotFound: "That transcript is no longer available."
        case .emptyTitle: "The new title can't be empty."
        }
    }
}
