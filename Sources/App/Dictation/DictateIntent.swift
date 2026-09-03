import AppIntents
import FCTEntities
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
/// `ReportingAppIntent` supplies `perform()`, so this writes ``run()``: an intent runs from Siri,
/// a Shortcut or a control with nobody watching, and a crash in one arrives with a trail that
/// would otherwise end at whatever the person last did by hand.
///
/// It is reachable from Shortcuts, Spotlight and Siri by name rather than by a canned phrase:
/// `TranscriptionShortcuts` is already at Apple's ten-shortcut cap, and past the cap a promoted
/// phrase is dropped with no error.
struct DictateIntent: ReportingAppIntent {
    static let title: LocalizedStringResource = "Dictate"
    static let description = IntentDescription(
        "Record a dictation, transcribe and clean it up on this device, and return the text.")
    /// The app has to be in front: the microphone runs in its process and Done is a button there.
    static let supportedModes: IntentModes = .foreground
    static let diagCrumb: any DiagBreadcrumb = TranscriptionCrumb.dictateIntent

    /// The registered app model, reached by holding the dependency wrapper rather than by
    /// applying it.
    ///
    /// `ReportingAppIntent` is a `nonisolated` protocol, and `nonisolated` cannot be applied to a
    /// mutable stored property — which is exactly what `@Dependency` declares, so the attribute
    /// form the app's other intents use does not compile on a conformer of this base. The wrapper
    /// is a class that resolves from `AppDependencyManager.shared` when read, so a `let` holding
    /// one resolves the same registration `@Dependency` would.
    private let appModelDependency = AppDependency<AppModel>()
    private var appModel: AppModel { appModelDependency.wrappedValue }

    init() {}

    /// Spelled out, and it has to be. `ReportingAppIntent` supplies `perform()` from a protocol
    /// extension, so nothing in this type declares one — and `PerformResult` is inferred from a
    /// `perform()` WITNESS, which here is the extension's, generic in exactly that type. With
    /// nothing to infer it from, the `AppIntent` conformance fails on the missing nested type
    /// however `run()` is written, so the conformer names it.
    typealias PerformResult = IntentResultContainer<String, OpenURLIntent, Never, Never>

    func run() async throws -> PerformResult {
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
}
