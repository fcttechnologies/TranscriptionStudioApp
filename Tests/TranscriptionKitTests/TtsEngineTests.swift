// The TTS seam: voice/language resolution (which must REJECT what TTSKit would silently
// substitute a default for), the request-vs-engine failure split the serve route keys its
// status codes off, and the WAV encoding every caller receives audio through. All model-free —
// none of it touches the ~1 GB weights, which is exactly the property the serve route relies on
// to reject a bad request without a download.

import AVFoundation
import Foundation
import Testing
@testable import TranscriptionKit

@Suite("TTSKitTtsEngine — voice + language resolution")
struct TtsVoiceResolutionTests {
    @Test func nilAndEmptyResolveToTheDefaults() throws {
        #expect(try TTSKitTtsEngine.resolvedVoice(nil) == TTSKitTtsEngine.defaultVoice)
        #expect(try TTSKitTtsEngine.resolvedVoice("") == TTSKitTtsEngine.defaultVoice)
        #expect(try TTSKitTtsEngine.resolvedVoice("  ") == TTSKitTtsEngine.defaultVoice)
        #expect(try TTSKitTtsEngine.resolvedLanguage(nil) == TTSKitTtsEngine.defaultLanguage)
        #expect(try TTSKitTtsEngine.resolvedLanguage("") == TTSKitTtsEngine.defaultLanguage)
    }

    @Test func theDefaultsAreThemselvesSupported() {
        #expect(TTSKitTtsEngine.supportedVoices.contains(TTSKitTtsEngine.defaultVoice))
        #expect(TTSKitTtsEngine.supportedLanguages.contains(TTSKitTtsEngine.defaultLanguage))
        #expect(TTSKitTtsEngine.supportedVoices.count > 1)
        #expect(TTSKitTtsEngine.supportedLanguages.count > 1)
    }

    @Test func everySupportedVoiceAndLanguageResolvesToItself() throws {
        for voice in TTSKitTtsEngine.supportedVoices {
            #expect(try TTSKitTtsEngine.resolvedVoice(voice) == voice)
        }
        for language in TTSKitTtsEngine.supportedLanguages {
            #expect(try TTSKitTtsEngine.resolvedLanguage(language) == language)
        }
    }

    @Test func resolutionIsCaseAndWhitespaceInsensitive() throws {
        let voice = TTSKitTtsEngine.supportedVoices[0]
        #expect(try TTSKitTtsEngine.resolvedVoice("  \(voice.uppercased()) ") == voice)
        let language = TTSKitTtsEngine.supportedLanguages[0]
        #expect(try TTSKitTtsEngine.resolvedLanguage(language.uppercased()) == language)
    }

    /// The load-bearing one: TTSKit falls back to its own default speaker for an unrecognized
    /// string, so a typo would hand the caller a different voice with no signal. Resolution here
    /// must throw instead — and name what IS available.
    @Test func anUnknownVoiceThrowsRatherThanSubstitutingADefault() {
        #expect(throws: TtsEngineError.unsupportedVoice("gandalf", supported: TTSKitTtsEngine.supportedVoices)) {
            try TTSKitTtsEngine.resolvedVoice("gandalf")
        }
    }

    @Test func anUnknownLanguageThrowsRatherThanSubstitutingADefault() {
        #expect(throws: TtsEngineError.unsupportedLanguage("klingon", supported: TTSKitTtsEngine.supportedLanguages)) {
            try TTSKitTtsEngine.resolvedLanguage("klingon")
        }
    }

    @Test func validateRejectsEmptyAndWhitespaceOnlyText() {
        let engine = TTSKitTtsEngine()
        #expect(throws: TtsEngineError.emptyText) { try engine.validate(text: "", voice: nil, language: nil) }
        #expect(throws: TtsEngineError.emptyText) { try engine.validate(text: " \n\t ", voice: nil, language: nil) }
    }

    @Test func validateAcceptsARealRequest() throws {
        let engine = TTSKitTtsEngine()
        try engine.validate(text: "Hello.", voice: TTSKitTtsEngine.supportedVoices[0], language: nil)
    }

    /// Synthesis without a loaded model is an engine failure, not a request failure — the seam
    /// says so, and the serve route's 500 depends on it.
    @Test func synthesizingBeforePrepareThrowsNotPrepared() async {
        let engine = TTSKitTtsEngine()
        await #expect(throws: TtsEngineError.notPrepared) {
            try await engine.synthesize(text: "Hello.", voice: nil, language: nil)
        }
    }
}

@Suite("TtsEngineError — the request-vs-engine split")
struct TtsEngineErrorTests {
    @Test func onlyTheCallersMistakesCountAsInvalidRequests() {
        #expect(TtsEngineError.emptyText.isInvalidRequest)
        #expect(TtsEngineError.unsupportedVoice("x", supported: ["a"]).isInvalidRequest)
        #expect(TtsEngineError.unsupportedLanguage("x", supported: ["a"]).isInvalidRequest)
        #expect(!TtsEngineError.notPrepared.isInvalidRequest)
        #expect(!TtsEngineError.modelDownloadFailed(underlying: "offline").isInvalidRequest)
        #expect(!TtsEngineError.synthesisFailed("boom").isInvalidRequest)
        #expect(!TtsEngineError.audioEncodingFailed("boom").isInvalidRequest)
    }

    @Test func everyCaseDescribesItselfUsefully() {
        let cases: [TtsEngineError] = [
            .emptyText,
            .unsupportedVoice("gandalf", supported: ["ryan", "serena"]),
            .unsupportedLanguage("klingon", supported: ["english"]),
            .notPrepared,
            .modelDownloadFailed(underlying: "network gone"),
            .synthesisFailed("no audio"),
            .audioEncodingFailed("bad buffer")
        ]
        let messages = cases.map { $0.errorDescription ?? "" }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == cases.count)
        #expect(messages[1].contains("gandalf"))
        #expect(messages[1].contains("serena"))
        #expect(messages[4].contains("network gone"))
    }
}

@Suite("SynthesizedSpeech — WAV encoding")
struct SynthesizedSpeechTests {
    private func tone(seconds: Double, sampleRate: Int) -> SynthesizedSpeech {
        let count = Int(seconds * Double(sampleRate))
        let samples = (0..<count).map { index in
            Float(sin(2 * .pi * 440 * Double(index) / Double(sampleRate)) * 0.5)
        }
        return SynthesizedSpeech(samples: samples, sampleRate: sampleRate)
    }

    @Test func durationIsSamplesOverRate() {
        #expect(tone(seconds: 1.5, sampleRate: 24_000).duration == 1.5)
        #expect(SynthesizedSpeech(samples: [], sampleRate: 24_000).duration == 0)
        // A zero rate can't divide — report no duration rather than trapping.
        #expect(SynthesizedSpeech(samples: [0, 0], sampleRate: 0).duration == 0)
    }

    @Test func encodesARiffWavContainer() throws {
        let data = try tone(seconds: 0.25, sampleRate: 24_000).wavData()
        #expect(data.count > 44)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data[data.startIndex + 8..<data.startIndex + 12] == Data("WAVE".utf8))
    }

    /// The audio carries its own rate — that's what lets a client play a `/speak` response back
    /// without being told which model produced it.
    @Test(arguments: [24_000, 48_000])
    func roundTripsBackToMonoAudioOfTheSameLengthAndRate(sampleRate: Int) throws {
        let speech = tone(seconds: 0.25, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try speech.wavData().write(to: url)

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.fileFormat.sampleRate == Double(sampleRate))
        #expect(file.fileFormat.channelCount == 1)
        #expect(Int(file.length) == speech.samples.count)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let decoded = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                count: Int(buffer.frameLength)))
        // 16-bit quantization, so assert the signal's shape survived rather than exact samples.
        #expect((decoded.map(abs).max() ?? 0) > 0.4)
    }

    @Test func encodingNothingIsAnEngineFailureNotAnEmptyFile() {
        #expect(throws: TtsEngineError.self) {
            try SynthesizedSpeech(samples: [], sampleRate: 24_000).wavData()
        }
    }
}
