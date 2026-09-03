// The dictation adoption's own logic: the URL route this app shares with the Share extension's
// ping, the diarizer pass's segment labelling, the vocabulary the cleanup is handed, and the
// suspension an intent waits on between "start recording" and "Done".
//
// The recorder, Apple's transcriber and the model are all absent here by design — `DictationRun`
// is built over protocols precisely so the assembly can be proven without hardware, and what the
// package's own suite already covers is not re-covered.

import FCTDictation
import FCTIntelligence
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

// MARK: - Fakes

/// Hands back a fixed recording without touching the microphone.
private final class FakeCapture: DictationAudioCapturing, @unchecked Sendable {
    let id = UUID()

    @discardableResult
    func start() async throws -> UUID { id }

    func stop() async throws -> DictationRecording {
        DictationRecording(
            id: id,
            url: URL(filePath: NSTemporaryDirectory()).appending(path: "\(id.uuidString).caf"),
            duration: 2
        )
    }
}

private final class FakeDictationEngine: DictationEngine, @unchecked Sendable {
    let identifier = "test.engine"
    let text: String

    init(text: String) { self.text = text }

    func prepare(onProgress: @escaping @Sendable (DictationPreparationProgress) -> Void) async throws {
        onProgress(DictationPreparationProgress(phase: "installed", fraction: 1))
    }

    func transcribe(_ recording: DictationRecording) async throws -> DictationTranscript {
        DictationTranscript(
            segments: [DictationSegment(text: text, start: 0, end: recording.duration)],
            locale: Locale(identifier: "en_US"),
            engineIdentifier: identifier
        )
    }
}

private final class FakeClipboard: DictationClipboard, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    func copy(_ text: String) { lock.withLock { texts.append(text) } }
    var copied: [String] { lock.withLock { texts } }
}

/// No model tier, so the cleanup pass is deterministic: it degrades to the raw transcript and
/// says `.modelUnavailable`. Without this the assertions below would depend on whether the Mac
/// running them happens to have Apple Intelligence, which is a flake, not a test.
private struct NoModelAvailable: ModelAvailabilityProbing {
    let isOnDeviceModelAvailable = false
    let isPCCAvailable = false
}

/// A run over the app's real store — the test host is the app, so the App Group resolves — with
/// every other stage faked. The store is the one piece worth keeping real: the hand-off is the
/// container round trip, and a fake would prove nothing about it.
@MainActor
private func makeTestRun(
    text: String, clipboard: FakeClipboard
) throws -> (run: DictationRun, store: DictationStore) {
    let store = try DictationStore(appGroupID: StudioDictation.appGroupID)
    let run = DictationRun(
        recorder: FakeCapture(),
        engine: FakeDictationEngine(text: text),
        cleanup: DictationCleanup(extractor: GuidedExtractor(availability: NoModelAvailable())),
        store: store,
        clipboard: clipboard,
        route: StudioDictation.route
    )
    return (run, store)
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - The route

@Suite("Dictation route — one scheme, two hosts")
struct DictationRouteTests {

    @Test("A hand-off URL carries its result id back")
    func roundTripsAnID() {
        let id = UUID()
        let url = StudioDictation.route.url(for: id)
        #expect(StudioDictation.route.resultID(in: url) == id)
    }

    // The app registers ONE scheme for both the Share extension's ping and the dictation
    // hand-off, so the host is the only thing telling them apart. Each consumer must refuse the
    // other's URL, or a finished dictation drains the drop-box (or a shared item opens an empty
    // dictation) with nothing reporting it.
    @Test("The ingest ping is not a dictation hand-off")
    func ingestIsNotDictation() {
        let ingest = IngestURLScheme.ingestURL(id: UUID())
        #expect(StudioDictation.route.resultID(in: ingest) == nil)
    }

    @Test("A dictation hand-off is not an ingest ping")
    func dictationIsNotIngest() {
        let handoff = StudioDictation.route.url(for: UUID())
        #expect(IngestURLScheme.parseIngest(handoff) == nil)
    }
}

// MARK: - The diarizer pass

@Suite("SpeakerDictationPass — labelling a dictation's segments")
struct SpeakerDictationPassTests {

    @Test("Each segment takes the speaker whose turn covers it")
    func labelsFromOverlap() {
        let segments = [
            DictationSegment(text: "first", start: 0, end: 2),
            DictationSegment(text: "second", start: 2, end: 4),
        ]
        let turns = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 2, confidence: 0.9),
            SpeakerTurn(speakerIndex: 1, start: 2, end: 4, confidence: 0.9),
        ]
        let labelled = SpeakerDictationPass.labelled(segments, with: turns)
        #expect(labelled.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(labelled.map(\.text) == ["first", "second"])
    }

    // `.unknown` is the fuser saying it does not know. Writing that word onto a line would read
    // as a speaker actually named Unknown, so an uncovered segment stays unlabelled.
    @Test("A segment no turn covers stays unlabelled rather than named Unknown")
    func uncoveredSegmentStaysNil() {
        let segments = [DictationSegment(text: "alone", start: 10, end: 12)]
        let turns = [SpeakerTurn(speakerIndex: 0, start: 0, end: 2, confidence: 0.9)]
        #expect(SpeakerDictationPass.labelled(segments, with: turns).first?.speaker == nil)
    }

    @Test("No turns at all leaves every segment as it was")
    func noTurnsChangesNothing() {
        let segments = [DictationSegment(text: "one", start: 0, end: 1)]
        #expect(SpeakerDictationPass.labelled(segments, with: []) == segments)
    }
}

// MARK: - The vocabulary

@Suite("Dictation vocabulary — what the cleanup is told to spell")
@MainActor
struct DictationVocabularyTests {

    private func makeApp() -> AppModel {
        AppModel(modelContext: ModelContextFactory.makeInMemory())
    }

    @Test("Speakers the person bound by hand are the vocabulary's people")
    func boundSpeakersBecomePeople() async {
        let app = makeApp()
        let session = TranscriptSession(title: "Standup", kind: .roomRecording)
        app.modelContext.insert(session)
        SpeakerAssignmentStore.assign(
            slot: 0, contactIdentifier: "c1", displayName: "Sergio Ramos",
            to: session, in: app.modelContext)
        SpeakerAssignmentStore.assign(
            slot: 1, contactIdentifier: "c2", displayName: "Aoife Ní Bhraonáin",
            to: session, in: app.modelContext)

        let vocabulary = await app.dictationVocabulary()
        #expect(vocabulary.people.contains("Sergio Ramos"))
        #expect(vocabulary.people.contains("Aoife Ní Bhraonáin"))
    }

    // The order is load-bearing: `normalized(limit:)` cuts from the END of the people list, so a
    // hand-bound speaker arriving after a hundred contacts would be the first thing dropped. It is
    // asserted on the composition rather than through `dictationVocabulary()`, because a machine
    // with no Contacts access reads an empty second list and could not tell the orders apart.
    @Test("A bound speaker outranks a contact, so it survives the normalizer's cut")
    func boundSpeakerSurvivesTheCut() {
        let vocabulary = DictationVocabularyBudget.vocabulary(
            speakers: ["Sergio Ramos"], contacts: (1...200).map { "Contact \($0)" })
        #expect(vocabulary.normalized(limit: 1).people == ["Sergio Ramos"])
    }

    @Test("The same name bound to two slots is one entry")
    func duplicatesCollapse() async {
        let app = makeApp()
        let first = TranscriptSession(title: "Monday", kind: .roomRecording)
        let second = TranscriptSession(title: "Tuesday", kind: .roomRecording)
        app.modelContext.insert(first)
        app.modelContext.insert(second)
        SpeakerAssignmentStore.assign(
            slot: 0, contactIdentifier: "c1", displayName: "Sergio Ramos",
            to: first, in: app.modelContext)
        SpeakerAssignmentStore.assign(
            slot: 0, contactIdentifier: "c1", displayName: "sergio ramos",
            to: second, in: app.modelContext)

        let people = await app.dictationVocabulary().people
        #expect(people.filter { $0.lowercased() == "sergio ramos" }.count == 1)
    }
}

// MARK: - The suspension an intent waits on

@Suite("StudioDictation — the Done affordance")
@MainActor
struct StudioDictationTests {

    @Test("Done taken before the intent reaches waitForDone does not hang it")
    func doneBeforeWaitReturnsImmediately() async throws {
        let dictation = StudioDictation()
        let clipboard = FakeClipboard()
        let (run, _) = try makeTestRun(text: "hello there", clipboard: clipboard)
        try await dictation.begin { run }
        #expect(dictation.isRecording)

        // A two-word dictation can be finished before the intent's next line runs. If the wait
        // only ever resumed a continuation stored later, this would never return.
        dictation.markDone()
        await dictation.waitForDone()
    }

    @Test("Done, then finish: the text is the result and it reaches the clipboard")
    func finishProducesTheResult() async throws {
        let dictation = StudioDictation()
        let clipboard = FakeClipboard()
        let (run, store) = try makeTestRun(text: "hello there", clipboard: clipboard)
        try await dictation.begin { run }
        dictation.markDone()
        await dictation.waitForDone()
        let handoff = try await dictation.finish(vocabulary: .empty)

        #expect(handoff.result.rawText == "hello there")
        #expect(clipboard.copied == [handoff.result.text])
        #expect(dictation.phase == .finished)
        #expect(dictation.result?.id == handoff.result.id)
        // The hand-off's whole point: the app the URL opens reads the result out of the
        // container, so it has to be there before the URL is handed back.
        #expect(StudioDictation.route.resultID(in: handoff.openURL) == handoff.result.id)
        #expect(try store.consume(handoff.result.id)?.text == handoff.result.text)
    }

    @Test("Cancel stops the recorder and refuses to hand anything back")
    func cancelThrows() async throws {
        let dictation = StudioDictation()
        let clipboard = FakeClipboard()
        let (run, _) = try makeTestRun(text: "never mind", clipboard: clipboard)
        try await dictation.begin { run }
        dictation.cancel()
        await dictation.waitForDone()

        await #expect(throws: DictationError.self) {
            try await dictation.finish(vocabulary: .empty)
        }
        #expect(dictation.result == nil)
        #expect(dictation.phase == .idle)
    }

    // The control returns the moment the app is foregrounded — nobody is left waiting on Done —
    // so the app has to drive the rest itself. A `begin()` with no `finish()` behind it is a Done
    // button wired to nothing and a microphone left open, and it looks identical until you press it.
    @Test("A control-started dictation runs to a finished result on its own")
    func controlPathRunsToCompletion() async throws {
        let app = AppModel(modelContext: ModelContextFactory.makeInMemory())
        let clipboard = FakeClipboard()
        let (run, store) = try makeTestRun(text: "note to self", clipboard: clipboard)
        app.dictationRunFactory = { run }

        app.beginDictation()
        #expect(app.activeSheet == .dictation)
        try await waitUntil(timeout: 5) { app.dictation.isRecording }

        app.dictation.markDone()
        try await waitUntil(timeout: 10) { app.dictation.phase == .finished }

        #expect(app.dictation.result?.rawText == "note to self")
        #expect(clipboard.copied == ["note to self"])
        if let id = app.dictation.result?.id { _ = try? store.consume(id) }
    }

    @Test("An assembly that throws lands on the phase rather than a silent no-op")
    func assemblyFailureIsRecorded() async {
        let dictation = StudioDictation()
        struct Refused: Error {}
        await #expect(throws: Refused.self) {
            try await dictation.begin { throw Refused() }
        }
        guard case .failed = dictation.phase else {
            Issue.record("expected a failed phase, got \(dictation.phase)")
            return
        }
    }
}
