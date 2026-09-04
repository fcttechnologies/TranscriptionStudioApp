import FCTMetrics
import Foundation
import AppIntents

/// Which kind of ecosystem write an intent couldn't find anything to draft.
enum EcosystemItemKind: Sendable {
    case event, actionItem

    var noneMessage: LocalizedStringResource {
        switch self {
        case .event: "That transcript has no meetings or events to add."
        case .actionItem: "That transcript has no action items to add."
        }
    }

    var chooseDialog: IntentDialog {
        switch self {
        case .event: IntentDialog("Which event would you like to add?")
        case .actionItem: IntentDialog("Which action item would you like to add?")
        }
    }
}

enum EcosystemIntentError: Error, CustomLocalizedStringResourceConvertible {
    case transcriptNotFound
    case nothingToAdd(EcosystemItemKind)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .transcriptNotFound: "That transcript is no longer available."
        case .nothingToAdd(let kind): kind.noneMessage
        }
    }
}

/// **Flagship B — Calendar.** "Add the meeting from this transcript to my calendar." Resolves the
/// session's extracted events (disambiguating when there are several), then opens the app to the
/// **draft-then-confirm** sheet — the write itself only happens when the user taps Add there, never
/// headlessly from voice. Parameterized by a `TranscriptSessionEntity` so Siri/Shortcuts can target
/// any saved transcript.
struct AddEventToCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Meeting to Calendar"
    static let description = IntentDescription(
        "Review a meeting or event found in a transcript and add it to your calendar.")
    static let supportedModes: IntentModes = .foreground(.dynamic)
    static var parameterSummary: some ParameterSummary { Summary("Add an event from \(\.$session) to Calendar") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript's event would you like to add?"))
    var session: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        func run() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
            guard let sessionID = UUID(uuidString: session.id) else { throw EcosystemIntentError.transcriptNotFound }
            let events = await EcosystemActionStore.events(forSessionID: sessionID)
            guard let chosen = try await EcosystemChoice.pick(events, kind: .event, from: self) else {
                throw EcosystemIntentError.nothingToAdd(.event)
            }
            await MainActor.run { appModel.activeSheet = .confirmCalendarEvent(chosen.id) }
            return .result(opensIntent: OpenAppIntent(),
                           dialog: "Review “\(chosen.label)” before adding it to your calendar.")
        }
        return try await Diag.intent(TranscriptionCrumb.addEventToCalendarIntent, run)
    }
}

/// **Flagship B — Reminders.** "Set a reminder for the action item from this transcript." Same
/// draft-then-confirm routing as `AddEventToCalendarIntent`, over the session's extracted action
/// items.
struct AddActionItemReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Action Item to Reminders"
    static let description = IntentDescription(
        "Review an action item found in a transcript and add it to Reminders.")
    static let supportedModes: IntentModes = .foreground(.dynamic)
    static var parameterSummary: some ParameterSummary { Summary("Add an action item from \(\.$session) to Reminders") }

    @Parameter(title: "Transcript",
               requestValueDialog: IntentDialog("Which transcript's action item would you like to add?"))
    var session: TranscriptSessionEntity

    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
        func run() async throws -> some IntentResult & OpensIntent & ProvidesDialog {
            guard let sessionID = UUID(uuidString: session.id) else { throw EcosystemIntentError.transcriptNotFound }
            let items = await EcosystemActionStore.actionItems(forSessionID: sessionID)
            guard let chosen = try await EcosystemChoice.pick(items, kind: .actionItem, from: self) else {
                throw EcosystemIntentError.nothingToAdd(.actionItem)
            }
            await MainActor.run { appModel.activeSheet = .confirmReminder(chosen.id) }
            return .result(opensIntent: OpenAppIntent(),
                           dialog: "Review “\(chosen.label)” before adding it to Reminders.")
        }
        return try await Diag.intent(TranscriptionCrumb.addActionItemReminderIntent, run)
    }
}

/// The shared "one of N" disambiguation for the ecosystem intents — go straight through for a single
/// item, otherwise present a system choice keyed back to the chosen item by `Equatable` identity.
enum EcosystemChoice {
    static func pick(_ items: [EcosystemActionItemRef], kind: EcosystemItemKind,
                     from intent: some AppIntent) async throws -> EcosystemActionItemRef? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.first }
        let options = items.map { IntentChoiceOption(title: title(for: $0)) }
        let chosen = try await intent.requestChoice(between: options, dialog: kind.chooseDialog)
        guard let index = options.firstIndex(of: chosen) else { return nil }
        return items[index]
    }

    private static func title(for ref: EcosystemActionItemRef) -> LocalizedStringResource {
        ref.detail.isEmpty ? "\(ref.label)" : "\(ref.label) — \(ref.detail)"
    }
}
