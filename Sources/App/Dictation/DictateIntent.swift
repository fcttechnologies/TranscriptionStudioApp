import AppIntents
import FCTMetrics
import Foundation

/// Speak, get clean text back — the Shortcuts and Siri verb for a dictation.
///
/// It is a declaration and nothing else: `FCTDictation`'s `DictationRun` owns the order the stages
/// run in and the id the recording, the stored result and the URL share, and `StudioDictation`
/// owns the suspension in the middle where the person is speaking. What is here is the shape the
/// system needs — a title, a foreground mode, and a result carrying the text plus the URL that
/// opens the app onto it.
///
/// The body runs inside `Diag.intent(_:_:)`, hoisted into a nested `run()`: an intent runs from
/// Siri, a Shortcut or a control with nobody watching, and a crash in one arrives with a trail
/// that would otherwise end at whatever the person last did by hand.
///
/// It is reachable from Shortcuts, Spotlight and Siri by name rather than by a canned phrase:
/// `TranscriptionShortcuts` is already at Apple's ten-shortcut cap, and past the cap a promoted
/// phrase is dropped with no error.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let description = IntentDescription(
        "Record a dictation, transcribe and clean it up on this device, and return the text.")
    /// The app has to be in front: the microphone runs in its process and Done is a button there.
    static let supportedModes: IntentModes = .foreground

    /// The registered app model, the same attribute form every other intent in this app uses.
    @Dependency private var appModel: AppModel

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> & OpensIntent {
        func run() async throws -> some IntentResult & ReturnsValue<String> & OpensIntent {
            let dictation = await MainActor.run {
                appModel.activeSheet = .dictation
                return appModel.dictation
            }
            try await dictation.begin { try appModel.makeDictationRun() }
            await dictation.waitForDone()
            let vocabulary = await appModel.dictationVocabulary()
            let handoff = try await dictation.finish(vocabulary: vocabulary)
            return .result(value: handoff.result.text, opensIntent: OpenURLIntent(handoff.openURL))
        }
        return try await Diag.intent(TranscriptionCrumb.dictateIntent, run)
    }
}
