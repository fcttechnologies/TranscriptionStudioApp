// The cloning voice path's pure layers and model-free contracts: profile parsing, the
// 5-second prompt-transcript matching, sentence chunking, the engine's validation, and the
// voice router. Nothing here touches a model — the CoreML pipeline itself is covered by the
// env-gated `LuxTtsLiveTests`.

import Foundation
import Synchronization
import Testing
@testable import TranscriptionStudio

// MARK: - CloningVoiceProfile

@Suite("CloningVoiceProfile — the voice roster file")
struct CloningVoiceProfileTests {
    /// The real profile's shape: extra fields everywhere, `ref_audio` relative to the file.
    private func writeProfile(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloning-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("voice-profile.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func parsesReferencesAndResolvesPathsRelativeToTheProfile() throws {
        let url = try writeProfile("""
        {
          "schema_version": 2,
          "tool": "something-stale",
          "purpose": "irrelevant to the loader",
          "primary": "operational",
          "references": {
            "operational": {
              "ref_audio": "assets/operational.wav",
              "ref_text": "words beyond the five second cut must not be trusted",
              "register": "workshop",
              "duration_seconds": 5.92
            },
            "welcoming": { "ref_audio": "assets/welcoming.wav" }
          }
        }
        """)
        let profile = try CloningVoiceProfile.load(from: url)
        #expect(profile.primaryVoice == "operational")
        #expect(profile.voiceIDs == ["operational", "welcoming"])
        #expect(profile.references["operational"]?.audioURL.path
                == url.deletingLastPathComponent().appendingPathComponent("assets/operational.wav").path)
    }

    @Test func rejectsAPrimaryThatIsNotAReference() throws {
        let url = try writeProfile("""
        { "primary": "ghost", "references": { "real": { "ref_audio": "a.wav" } } }
        """)
        #expect(throws: TtsEngineError.self) { try CloningVoiceProfile.load(from: url) }
    }

    @Test func rejectsAMissingOrMalformedFile() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/voice-profile.json")
        #expect(throws: TtsEngineError.self) { try CloningVoiceProfile.load(from: missing) }
        let malformed = try writeProfile("{ not json")
        #expect(throws: TtsEngineError.self) { try CloningVoiceProfile.load(from: malformed) }
    }
}

// MARK: - PromptTranscript

@Suite("PromptTranscript — the 5-second prompt contract")
struct PromptTranscriptTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> AsrWord {
        AsrWord(word: text, start: start, end: end, probability: 1)
    }

    @Test func keepsOnlyWordsFullyInsideTheWindowInSpokenOrder() {
        // Deliberately out of order — Whisper segments can hand words segment-grouped.
        let words = [
            word(" simulations", 1.2, 2.0),
            word(" I", 0.1, 0.3),
            word(" have", 0.3, 0.6),
            word(" run", 0.6, 1.2),
            word(" Palladium", 5.4, 6.1),  // past the window entirely
        ]
        #expect(PromptTranscript.matched(words: words).text == "I have run simulations")
    }

    /// A word the 5.0 s cut clipped mid-way is transcribed as ending at the audio's end;
    /// claiming it in the transcript makes the model speak the unheard half. The guard band
    /// drops anything ending inside the last 50 ms.
    @Test func dropsAWordEndingInsideTheCutGuardBand() {
        let words = [word("viable", 4.0, 4.6), word("replacement", 4.6, 4.98)]
        #expect(PromptTranscript.matched(words: words).text == "viable")
        // …while a word that genuinely finishes before the band survives.
        #expect(PromptTranscript.matched(words: [word("done", 4.4, 4.94)]).text == "done")
    }

    /// The clip cut lands just past the last kept word — the audio must hold exactly the
    /// transcribed words. A dangling half-word left in the clip is *completed by the model*
    /// at the start of every generation (the live "a…" seam artifact).
    @Test func clipCutSitsJustPastTheLastKeptWord() {
        // Padded tail, capped at the window.
        let padded = PromptTranscript.matched(words: [word("done", 4.0, 4.5)])
        #expect(abs(padded.clipSeconds - 4.58) < 0.0001)
        let atWindow = PromptTranscript.matched(words: [word("done", 4.0, 4.94)])
        #expect(atWindow.clipSeconds == 5.0)
    }

    @Test func clipCutNeverPadsIntoADroppedWord() {
        // "such" kept (ends 4.90), the clipped word starts at 4.93 — the cut must stop there.
        let words = [word("such", 4.4, 4.90), word("succ-", 4.93, 5.0)]
        let matched = PromptTranscript.matched(words: words)
        #expect(matched.text == "such")
        #expect(abs(matched.clipSeconds - 4.93) < 0.0001)
    }

    @Test func emptyInputYieldsEmptyPrompt() {
        #expect(PromptTranscript.matched(words: []) == PromptTranscript.MatchedPrompt(text: "", clipSeconds: 0))
    }

    /// A transcript ending mid-phrase ("…They were such a") makes the model complete the
    /// dangling phrase at the start of every generation — heard live as a stray "A." between
    /// chunks. When a sentence boundary exists inside the window (past the minimum prompt
    /// length), the prompt ends there instead: complete sentences, nothing to complete.
    @Test func prefersEndingAtTheLastSentenceBoundary() {
        let words = [
            word("Welcome", 0.2, 0.6), word("home,", 0.6, 1.0), word("sir.", 1.0, 1.4),
            word("Congratulations", 1.8, 2.6), word("on", 2.6, 2.7), word("the", 2.7, 2.8),
            word("opening", 2.8, 3.2), word("ceremonies.", 3.2, 3.9),
            word("They", 4.1, 4.3), word("were", 4.3, 4.5), word("such", 4.5, 4.7),
            word("a", 4.7, 4.8),
        ]
        let matched = PromptTranscript.matched(words: words)
        #expect(matched.text == "Welcome home, sir. Congratulations on the opening ceremonies.")
        // Cut just past "ceremonies." (3.9 + pad), well before "They" starts.
        #expect(abs(matched.clipSeconds - 3.98) < 0.0001)
    }

    /// One long sentence with no internal boundary (the operational clip's shape) keeps the
    /// full matched window — the exact prompt the bench's decisive clips ran with.
    @Test func aBoundarylessTranscriptKeepsTheFullWindow() {
        let words = [
            word("I", 0.1, 0.2), word("have", 0.2, 0.5), word("run", 0.5, 0.9),
            word("simulations", 0.9, 1.8), word("on", 1.8, 1.9), word("every", 1.9, 2.3),
            word("known", 2.3, 2.6), word("element,", 2.6, 3.2), word("and", 3.2, 3.4),
            word("none", 3.4, 3.7), word("can", 3.7, 3.9), word("serve", 3.9, 4.2),
            word("as", 4.2, 4.3), word("a", 4.3, 4.4), word("viable", 4.4, 4.8),
            word("replacement", 4.8, 4.9),
        ]
        let matched = PromptTranscript.matched(words: words)
        #expect(matched.text.hasSuffix("viable replacement"))
        #expect(abs(matched.clipSeconds - 4.98) < 0.0001)
    }

    /// A sentence boundary too early in the clip would gut the voice conditioning — below the
    /// minimum prompt length the full matched window wins over the clean ending.
    @Test func anEarlySentenceBoundaryDoesNotShortenThePromptBelowTheMinimum() {
        let words = [
            word("Yes.", 0.2, 0.5),
            word("The", 1.0, 1.2), word("results", 1.2, 1.8), word("look", 1.8, 2.2),
            word("promising", 2.2, 2.9), word("so", 2.9, 3.1), word("far", 3.1, 3.4),
        ]
        let matched = PromptTranscript.matched(words: words)
        #expect(matched.text == "Yes. The results look promising so far")
        #expect(abs(matched.clipSeconds - 3.48) < 0.0001)
    }
}

// MARK: - SentenceChunker

@Suite("SentenceChunker — the per-call generation cap")
struct SentenceChunkerTests {
    @Test func splitsOnTerminatorsKeepingThem() {
        let text = "The build is green. All tests pass! Anything else?"
        #expect(SentenceChunker.sentences(in: text)
                == ["The build is green.", "All tests pass!", "Anything else?"])
    }

    @Test func textWithoutATerminatorComesBackWhole() {
        #expect(SentenceChunker.sentences(in: "no terminator here") == ["no terminator here"])
    }

    @Test func trailingTextAfterTheLastTerminatorIsItsOwnChunk() {
        #expect(SentenceChunker.sentences(in: "Done. And one more thing")
                == ["Done.", "And one more thing"])
    }

    @Test func whitespaceOnlyAndEmptyYieldNothing() {
        #expect(SentenceChunker.sentences(in: "   \n ").isEmpty)
        #expect(SentenceChunker.sentences(in: "").isEmpty)
    }

    @Test func halvesSplitAtTheMiddleWordBoundary() throws {
        let (first, second) = try #require(SentenceChunker.halves(of: "one two three four five"))
        #expect(first == "one two")
        #expect(second == "three four five")
    }

    @Test func aSingleWordCannotBeHalved() {
        #expect(SentenceChunker.halves(of: "supercalifragilistic") == nil)
    }
}

// MARK: - LuxTtsCloningEngine (model-free contracts)

@Suite("LuxTtsCloningEngine — validation and the unprepared contract")
struct LuxTtsCloningEngineValidationTests {
    private func makeEngine() -> LuxTtsCloningEngine {
        let profile = CloningVoiceProfile(
            references: [
                "operational": .init(id: "operational",
                                     audioURL: URL(fileURLWithPath: "/tmp/nonexistent-op.wav")),
                "welcoming": .init(id: "welcoming",
                                   audioURL: URL(fileURLWithPath: "/tmp/nonexistent-wel.wav")),
            ],
            primaryVoice: "operational")
        return LuxTtsCloningEngine(profile: profile, promptAsr: { _ in [] })
    }

    @Test func validatesModelFree() throws {
        let engine = makeEngine()
        try engine.validate(text: "Hello.", voice: nil, language: nil)          // primary default
        try engine.validate(text: "Hello.", voice: "welcoming", language: "en")
        try engine.validate(text: "Hello.", voice: "operational", language: "English")

        #expect(throws: TtsEngineError.emptyText) {
            try engine.validate(text: "  \n", voice: nil, language: nil)
        }
        #expect(throws: TtsEngineError.unsupportedVoice("ryan", supported: ["operational", "welcoming"])) {
            try engine.validate(text: "Hello.", voice: "ryan", language: nil)
        }
        #expect(throws: TtsEngineError.unsupportedLanguage("spanish",
                                                           supported: LuxTtsCloningEngine.supportedLanguages)) {
            try engine.validate(text: "Hello.", voice: nil, language: "spanish")
        }
    }

    /// The seam's contract: an unprepared engine refuses to synthesize rather than silently
    /// loading — residency is the warm-holder's decision, not the engine's.
    @Test func synthesizingUnpreparedThrowsNotPrepared() async {
        await #expect(throws: TtsEngineError.notPrepared) {
            _ = try await makeEngine().synthesize(text: "Hello.", voice: nil, language: nil)
        }
    }
}

// MARK: - VoiceRoutingTtsEngine

@Suite("VoiceRoutingTtsEngine — one seam, two engines")
struct VoiceRoutingTtsEngineTests {
    /// Preset at 24 kHz, cloning at 48 kHz — the output rate proves which engine answered.
    private func makeRouter() -> (VoiceRoutingTtsEngine, preset: MockTtsEngine, cloning: MockTtsEngine) {
        let preset = MockTtsEngine(sampleRate: 24_000)
        let cloning = MockTtsEngine(sampleRate: 48_000)
        let router = VoiceRoutingTtsEngine(preset: preset, presetVoices: ["mock"],
                                           cloning: cloning, cloningVoices: ["mock-alt"])
        return (router, preset, cloning)
    }

    @Test func routesByVoiceAndKeepsTheNilDefaultOnThePresetEngine() async throws {
        let (router, _, _) = makeRouter()
        #expect(try await router.synthesize(text: "Hi.", voice: nil, language: nil).sampleRate == 24_000)
        #expect(try await router.synthesize(text: "Hi.", voice: "mock", language: nil).sampleRate == 24_000)
        #expect(try await router.synthesize(text: "Hi.", voice: "mock-alt", language: nil).sampleRate == 48_000)
    }

    @Test func anUnknownVoiceListsBothRosters() {
        let (router, _, _) = makeRouter()
        #expect(throws: TtsEngineError.unsupportedVoice("gandalf", supported: ["mock", "mock-alt"])) {
            try router.validate(text: "Hi.", voice: "gandalf", language: nil)
        }
    }

    /// Preparation is lazy and per-target: the router's own prepare loads nothing, and a
    /// preset request never pages in the cloning model (or vice versa).
    @Test func preparesOnlyTheEngineARequestRoutesTo() async throws {
        let (router, preset, cloning) = makeRouter()
        try await router.prepare { _ in }
        #expect(await preset.prepareCount == 0)
        #expect(await cloning.prepareCount == 0)

        _ = try await router.synthesize(text: "Hi.", voice: nil, language: nil)
        #expect(await preset.prepareCount == 1)
        #expect(await cloning.prepareCount == 0)

        _ = try await router.synthesize(text: "Hi.", voice: "mock-alt", language: nil)
        #expect(await cloning.prepareCount == 1)
    }

    @Test func streamingForwardsToTheRoutedEngine() async throws {
        let (router, _, _) = makeRouter()
        let rates = Mutex<[Int]>([])
        try await router.synthesizeStreaming(text: "Hello there.", voice: "mock-alt", language: nil) { chunk in
            rates.withLock { $0.append(chunk.sampleRate) }
            return true
        }
        let seen = rates.withLock { $0 }
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0 == 48_000 })
    }
}
