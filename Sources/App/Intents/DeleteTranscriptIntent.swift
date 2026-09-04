import AppIntents
import FCTMetrics
import SwiftData

/// Delete a saved transcript, through the same `SessionDeletion` transaction the feed's swipe
/// runs. Confirms with a destructive choice first, since this can arrive from Siri or Shortcuts
/// with no confirmation UI already on screen.
struct DeleteTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Transcript"
    static let description = IntentDescription("Delete a saved transcript from Transcription Studio.")
    static let supportedModes: IntentModes = .foreground(.dynamic)
    static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$target)") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript would you like to delete?"))
    var target: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        func run() async throws -> some IntentResult & ProvidesDialog {
            guard let id = UUID(uuidString: target.id) else {
                throw DeleteTranscriptIntentError.transcriptNotFound
            }
            let context = appModel.modelContext
            let predicate = #Predicate<TranscriptSession> { $0.id == id }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            guard let session = try context.fetch(descriptor).first else {
                throw DeleteTranscriptIntentError.transcriptNotFound
            }

            let choice = try await requestChoice(
                between: [IntentChoiceOption(title: "Delete Transcript", style: .destructive), .cancel],
                dialog: IntentDialog("Delete \"\(session.title)\"? This action cannot be undone."))
            guard choice.style == .destructive else { throw DeleteTranscriptIntentError.cancelled }

            SessionDeletion.delete(session, in: context, app: appModel)

            return .result(dialog: "Transcript deleted.")
        }
        return try await Diag.intent(TranscriptionCrumb.deleteTranscriptIntent, run)
    }
}

enum DeleteTranscriptIntentError: Error, CustomLocalizedStringResourceConvertible {
    case transcriptNotFound
    case cancelled

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .transcriptNotFound: "That transcript is no longer available."
        case .cancelled: "Delete canceled."
        }
    }
}
