import FCTDictation
import FCTMetrics
import Foundation
import SwiftData

/// Where the app composes a dictation: the store, the route, the engine the person chose, and the
/// vocabulary gathered at the moment of use.
///
/// `FCTDictation` owns the sequence, so everything here is a decision only this app can make —
/// which engine, whether to identify speakers, and which words this person's dictation has to get
/// right. Apple's `SpeechTranscriber` is the default and downloads nothing of ours; the studio's
/// recognizer and the diarizer are the engines this app already ships, offered as an opt-in in
/// Settings and reached through the same instances a transcription job uses, so choosing them
/// costs no second model load.
extension AppModel {

    /// One dictation, assembled from the current settings — or from whatever a test injected.
    func makeDictationRun() throws -> DictationRun {
        if let dictationRunFactory { return try dictationRunFactory() }
        let store = try DictationStore(appGroupID: StudioDictation.appGroupID)
        let engine: any DictationEngine = switch settings.dictationEngine {
        case .appleSpeech: AppleSpeechEngine()
        case .studio: StudioDictationEngine(engine: asr)
        }
        let passes: [any DictationTranscriptPass] = settings.dictationIdentifiesSpeakers
            ? [SpeakerDictationPass(diarizer: diarizer)]
            : []
        return DictationRun(
            recorder: DictationRecorder(store: store),
            engine: engine,
            passes: passes,
            store: store,
            route: StudioDictation.route
        )
    }

    /// Run a dictation from end to end — the Control Center control's landing, and the app's own
    /// entry point.
    ///
    /// It drives the whole sequence, not just the start: nobody else is waiting on this one.
    /// `DictateIntent` suspends on Done itself because it has a value to hand back, but a control
    /// press returns the moment the app is foregrounded, so a `begin()` with no `finish()` behind
    /// it would leave the Done button wired to nothing and the microphone open.
    ///
    /// Every failure has already been recorded on the phase by the call that raised it, which is
    /// what the surface shows; a cancel resolves to `.idle` the same way.
    func beginDictation() {
        activeSheet = .dictation
        Task {
            do {
                try await dictation.begin { try makeDictationRun() }
                await dictation.waitForDone()
                // Gathered here rather than before `begin`, so a control press reaches a live
                // microphone without waiting on an address-book read first.
                _ = try await dictation.finish(vocabulary: await dictationVocabulary())
            } catch {}
        }
    }

    /// A finished dictation's hand-off URL: read the result out of the container and show it.
    ///
    /// Returns whether the URL was this route's, so the app's other scheme consumer is not also
    /// handed it. True even when nothing is filed under the id — a consumed result is consumed
    /// once, and a second open of the same URL is still not an ingest ping.
    @discardableResult
    func handleDictationURL(_ url: URL) -> Bool {
        guard let id = StudioDictation.route.resultID(in: url) else { return false }
        if let store = try? DictationStore(appGroupID: StudioDictation.appGroupID),
           let result = try? store.consume(id) {
            // A result is consumed once, so this counts a dictation whose words actually reached
            // the app rather than every open of the same URL.
            Diag.count(TranscriptionCounter.dictationsCompleted)
            dictation.present(result)
        }
        activeSheet = .dictation
        return true
    }

    /// The words this dictation should get right, gathered now and kept nowhere.
    ///
    /// Speakers the person bound by hand come first: a name they typed into this app is more
    /// likely to be dictated than an arbitrary card, and `DictationVocabulary.normalized(limit:)`
    /// cuts from the end. `contactNames` reads the address book only where access is already
    /// granted — a dictation is the wrong moment to raise a permission sheet, and the pass
    /// degrades to "no names" cleanly.
    func dictationVocabulary() async -> DictationVocabulary {
        DictationVocabularyBudget.vocabulary(
            speakers: boundSpeakerNames(),
            contacts: await DictationVocabulary.contactNames(limit: DictationVocabularyBudget.contacts))
    }

    /// Every name the person has bound to a speaker anywhere in the library, newest sessions
    /// first, de-duplicated case-insensitively.
    private func boundSpeakerNames() -> [String] {
        var descriptor = FetchDescriptor<SpeakerAssignment>()
        descriptor.fetchLimit = DictationVocabularyBudget.speakers
        guard let assignments = try? modelContext.fetch(descriptor) else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for assignment in assignments {
            let name = assignment.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }
}

/// How much of each source a dictation's vocabulary may draw.
///
/// The sum is deliberately over `DictationVocabulary`'s own 100-entry cut: the two lists overlap
/// heavily (a bound speaker IS usually a contact), so gathering more than the budget and letting
/// the normalizer collapse duplicates fills it with distinct names rather than with the same
/// person twice.
enum DictationVocabularyBudget {
    static let speakers = 40
    static let contacts = 100

    /// The two lists as one vocabulary. Pure, and separate from the reads, because the ORDER is
    /// the load-bearing part and a machine with no contacts access cannot demonstrate it.
    static func vocabulary(speakers: [String], contacts: [String]) -> DictationVocabulary {
        DictationVocabulary(people: speakers + contacts)
    }
}
