import AppIntents
import SwiftData

/// Delete a saved transcript — mirrors the home feed's delete: deletes the SwiftData
/// session (its archived `audioData` goes with it) and de-indexes it from Spotlight. Confirms
/// with a destructive choice first since this can run from Siri/Shortcuts with no confirmation
/// UI already on screen.
public struct DeleteTranscriptIntent: AppIntent {
    public static let title: LocalizedStringResource = "Delete Transcript"
    public static let description = IntentDescription("Delete a saved transcript from Transcription Studio.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)
    public static var parameterSummary: some ParameterSummary { Summary("Delete \(\.$target)") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript would you like to delete?"))
    public var target: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
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

        let deletedID = session.id
        context.delete(session)
        try? context.save()
        TranscriptSpotlightIndex.deindex(id: deletedID)
        // Same cleanup as the feed's delete: don't leave the finished job's card behind.
        appModel.jobs.removeJobs(forSessionID: deletedID)

        return .result(dialog: "Transcript deleted.")
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
