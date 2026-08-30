// The real CoreML LuxTTS pipeline, end to end: profile → prompt-transcript derivation via
// real word-timestamped WhisperKit ASR → sentence-chunked cloned synthesis. Env-gated like the
// Sortformer real-model suite — it downloads/loads the cloning models (~346 MB) and the ASR
// model, so it only runs when explicitly asked for:
//
//   LUXTTS_MODEL_OK=1 swift test --filter LuxTtsLive
//
// Needs a voice profile on disk: `LUXTTS_PROFILE` (path to a voice-profile.json), defaulting
// to the Jarvis profile this machine actually speaks with.

import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("LuxTtsLive — real cloned synthesis", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LUXTTS_MODEL_OK"] == "1"))
struct LuxTtsLiveTests {
    private static let profilePath = ProcessInfo.processInfo.environment["LUXTTS_PROFILE"]
        ?? NSString(string: "~/Jarvis/projects/portfolio/jarvis-voice/voice-profile.json").expandingTildeInPath

    /// A prepared engine over the machine's own profile. Weights and the prompt transcript are
    /// both disk-cached, so this is a model load and no ASR after the first ever run.
    private func preparedEngine() async throws -> LuxTtsCloningEngine {
        let profileURL = URL(fileURLWithPath: Self.profilePath)
        try #require(FileManager.default.fileExists(atPath: profileURL.path),
                     "no voice profile at \(profileURL.path) — set LUXTTS_PROFILE")
        let profile = try CloningVoiceProfile.load(from: profileURL)

        let asr = WhisperKitAsrEngine()
        let engine = LuxTtsCloningEngine(profile: profile) { samples in
            try await asr.prepare { _ in }
            return try await asr.transcribe(samples: samples, track: .mixed, wordTimestamps: true)
        }
        try await engine.prepare { _ in }
        return engine
    }

    @Test func clonesAMultiSentenceUtteranceAt48kHz() async throws {
        let engine = try await preparedEngine()

        let speech = try await engine.synthesize(
            text: "The build is green. Every test passed on the first try.",
            voice: nil, language: nil)
        #expect(speech.sampleRate == 48_000)
        // Two spoken sentences can't plausibly be under 2s or over 15s.
        #expect(speech.duration > 2)
        #expect(speech.duration < 15)
        // A real waveform, not silence.
        #expect(speech.samples.contains { abs($0) > 0.05 })
    }

    /// A sentence the model can't tokenize costs that sentence and nothing else. The trailing
    /// lone emoji is the shape that occurs in real notes: `SentenceChunker` gives every chunk
    /// but the last a terminator, and a terminator is itself speakable, so an untokenizable
    /// chunk is by construction the final one. Synthesis is deterministic for identical text,
    /// which makes "cost exactly the emoji" an exact sample-count equality rather than a range.
    @Test func aTrailingUnspeakableChunkCostsOnlyThatChunk() async throws {
        let engine = try await preparedEngine()

        let withEmoji = try await engine.synthesize(text: "All done for today. 🫶",
                                                    voice: nil, language: nil)
        let plain = try await engine.synthesize(text: "All done for today.",
                                                voice: nil, language: nil)

        #expect(withEmoji.samples.count == plain.samples.count)
        #expect(withEmoji.samples.contains { abs($0) > 0.05 })
    }

    /// The same containment mid-utterance: a single word too long for the per-call cap that
    /// `SentenceChunker.halves` can't split further bottoms out of the split-and-retry
    /// recursion and fails — and the sentences on both sides of it still speak.
    @Test func anUnspeakableChunkMidUtteranceCostsOnlyThatChunk() async throws {
        let engine = try await preparedEngine()
        let unsplittable = String(repeating: "supercalifragilistic", count: 30)

        let withJunk = try await engine.synthesize(
            text: "First part done. \(unsplittable). Second part done.", voice: nil, language: nil)
        let plain = try await engine.synthesize(text: "First part done. Second part done.",
                                                voice: nil, language: nil)

        #expect(withJunk.samples.count == plain.samples.count)
    }

    /// The floor under the skip: a text the model fails on *entirely* throws rather than
    /// answering with silence, so a genuinely broken model can't be masked as a short note.
    @Test func aWhollyUnspeakableTextStillThrows() async throws {
        let engine = try await preparedEngine()
        await #expect(throws: TtsEngineError.self) {
            _ = try await engine.synthesize(text: "🫶", voice: nil, language: nil)
        }
    }

    /// An emoji *inside* a sentence was never the problem — the chunk around it tokenizes — and
    /// the skip must not start dropping these.
    @Test func anInlineEmojiSpeaksNormally() async throws {
        let engine = try await preparedEngine()

        let speech = try await engine.synthesize(text: "Great news today 🎉 and the build is green.",
                                                 voice: nil, language: nil)
        #expect(speech.duration > 1)
        #expect(speech.samples.contains { abs($0) > 0.05 })
    }
}
