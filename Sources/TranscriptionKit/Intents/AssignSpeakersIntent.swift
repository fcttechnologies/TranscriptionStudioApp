#if os(iOS)
import Foundation
import AppIntents

/// **Speaker → contact mapping, Siri-invocable.** Opens the app to the speaker-naming sheet for a
/// transcript, where each diarized speaker can be bound to a contact through the system picker.
/// iOS-only — the system contact picker (`CNContactPickerViewController`) is a UIKit surface; macOS
/// speaker naming is a later, platform-specific pass. The binding itself needs no Contacts permission.
public struct AssignSpeakersIntent: AppIntent {
    public static let title: LocalizedStringResource = "Name Transcript Speakers"
    public static let description = IntentDescription(
        "Open a transcript to name its speakers by matching them to your contacts.")
    public static let supportedModes: IntentModes = .foreground(.dynamic)
    public static var parameterSummary: some ParameterSummary { Summary("Name the speakers in \(\.$session)") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript's speakers would you like to name?"))
    public var session: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    public init() {}

    public func perform() async throws -> some IntentResult & OpensIntent {
        guard let id = UUID(uuidString: session.id) else { throw EcosystemIntentError.transcriptNotFound }
        await MainActor.run { appModel.activeSheet = .assignSpeakers(id) }
        return .result(opensIntent: OpenAppIntent())
    }
}
#endif
