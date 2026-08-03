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
@testable import TranscriptionKit

@Suite("LuxTtsLive — real cloned synthesis",
       .enabled(if: ProcessInfo.processInfo.environment["LUXTTS_MODEL_OK"] == "1"))
struct LuxTtsLiveTests {
    private static let profilePath = ProcessInfo.processInfo.environment["LUXTTS_PROFILE"]
        ?? NSString(string: "~/Jarvis/projects/portfolio/jarvis-voice/voice-profile.json").expandingTildeInPath

    @Test func clonesAMultiSentenceUtteranceAt48kHz() async throws {
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
}
