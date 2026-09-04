#if os(iOS)
import FCTMetrics
import Foundation
import AppIntents

/// **Speaker → contact mapping, Siri-invocable.** Opens the app to the speaker-naming sheet for a
/// transcript, where each diarized speaker can be bound to a contact through the system picker.
/// iOS-only — the system contact picker (`CNContactPickerViewController`) is a UIKit surface; macOS
/// speaker naming is a later, platform-specific pass. The binding itself needs no Contacts permission.
struct AssignSpeakersIntent: AppIntent {
    static let title: LocalizedStringResource = "Name Transcript Speakers"
    static let description = IntentDescription(
        "Open a transcript to name its speakers by matching them to your contacts.")
    static let supportedModes: IntentModes = .foreground(.dynamic)
    static var parameterSummary: some ParameterSummary { Summary("Name the speakers in \(\.$session)") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript's speakers would you like to name?"))
    var session: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        func run() async throws -> some IntentResult & OpensIntent {
            guard let id = UUID(uuidString: session.id) else { throw EcosystemIntentError.transcriptNotFound }
            await MainActor.run { appModel.activeSheet = .assignSpeakers(id) }
            return .result(opensIntent: OpenAppIntent())
        }
        return try await Diag.intent(TranscriptionCrumb.assignSpeakersIntent, run)
    }
}
#endif
