import AVFoundation
import Foundation

/// One synthesized utterance: mono float samples plus the rate they were produced at. The rate
/// travels with the audio rather than being assumed the way `AudioChunk`'s fixed 16 kHz capture
/// rate is — each synthesis model has its own output rate, and the whole point of the seam is
/// that swapping the model doesn't reshape the callers.
public struct SynthesizedSpeech: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }

    /// The utterance as a 16-bit mono WAV file's bytes — the one wire-and-disk format for
    /// synthesis: it carries its own sample rate, so a caller never has to be told which model
    /// produced it, and everything can play it. `AVAudioFile` only writes to a URL, so this
    /// encodes to a temp `.wav`, closes the file to finalize the container, then reads it back
    /// (the same round-trip `AudioFileIO.encodeAAC` makes for the archive format).
    public func wavData() throws -> Data {
        guard !samples.isEmpty else { throw TtsEngineError.audioEncodingFailed("no audio samples to encode") }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            // Scoped so the file deallocates — finalizing the RIFF header — before the read.
            // Written as float and converted to 16-bit on the way out by `AVAudioFile`.
            let file = try AVAudioFile(forWriting: tempURL,
                                       settings: Self.wavSettings(sampleRate: sampleRate),
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw TtsEngineError.audioEncodingFailed("couldn't allocate an audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channel = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress!, count: samples.count)
                }
            }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: tempURL)
    }

    private static func wavSettings(sampleRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM,
         AVSampleRateKey: Double(sampleRate),
         AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false,
         AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }
}

/// User-facing synthesis failures. `isInvalidRequest` is the split callers act on: the caller's
/// fault versus the engine's.
public enum TtsEngineError: LocalizedError, Sendable, Equatable {
    case emptyText
    case unsupportedVoice(String, supported: [String])
    case unsupportedLanguage(String, supported: [String])
    case notPrepared
    case modelDownloadFailed(underlying: String)
    case synthesisFailed(String)
    case audioEncodingFailed(String)

    /// True when the request was at fault (nothing to say, a voice or language this engine
    /// doesn't have) rather than the engine — the serve route answers these 400, the rest 500,
    /// and a caller can retry a 500 unchanged where a 400 needs fixing first.
    public var isInvalidRequest: Bool {
        switch self {
        case .emptyText, .unsupportedVoice, .unsupportedLanguage: true
        case .notPrepared, .modelDownloadFailed, .synthesisFailed, .audioEncodingFailed: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "There's no text to speak."
        case let .unsupportedVoice(voice, supported):
            "Unknown voice \"\(voice)\". Available: \(supported.joined(separator: ", "))."
        case let .unsupportedLanguage(language, supported):
            "Unknown language \"\(language)\". Available: \(supported.joined(separator: ", "))."
        case .notPrepared:
            "The speech synthesis model isn't ready yet — call prepare() first."
        case let .modelDownloadFailed(underlying):
            "Couldn't download the speech synthesis model: \(underlying)"
        case let .synthesisFailed(message):
            "Speech synthesis failed: \(message)"
        case let .audioEncodingFailed(message):
            "Couldn't encode the synthesized audio: \(message)"
        }
    }
}

/// One increment of a streaming synthesis: the newly produced samples — never cumulative — at
/// the rate they were produced. Carries its own rate for the same reason `SynthesizedSpeech`
/// does: the first chunk is what tells a streaming consumer the format before any audio plays.
public struct SynthesizedSpeechChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// The synthesis seam — the TTS counterpart to `AsrEngine`. Text in, mono float PCM out; the
/// serve route, the CLI, and the app know only this.
///
/// `voice` and `language` are engine-specific identifiers, deliberately plain strings: a preset
/// speaker name for the model shipping today, a reference-clip identifier for a cloning engine
/// later. That is the whole seam — a second engine conforms here and every caller above it is
/// unchanged.
public protocol TtsEngine: AnyObject, Sendable {
    /// Reject a request this engine can't serve, without loading anything. Model-free by
    /// contract: an unloaded engine answers it exactly as a resident one does, so a typo'd
    /// voice or an empty string never triggers a multi-gigabyte model download.
    nonisolated func validate(text: String, voice: String?, language: String?) throws

    /// Idempotent: download/load the model as needed.
    func prepare(onProgress: @escaping @Sendable (EnginePreparationProgress) -> Void) async throws

    /// Synthesize one complete utterance. A `nil` voice or language takes the engine's own
    /// default; an unknown one throws rather than quietly substituting one.
    func synthesize(text: String, voice: String?, language: String?) async throws -> SynthesizedSpeech

    /// Synthesize one utterance, delivering audio increments in order as the model produces
    /// them — what lets a consumer start playing (or sending) before synthesis finishes.
    ///
    /// `onChunk` returns whether to continue: `false` cancels the rest of the synthesis, and a
    /// cancelled run returns normally (the caller asked to stop; nothing failed). An engine
    /// that can't produce audio incrementally satisfies this with the default implementation —
    /// the complete utterance as one chunk — so a streaming consumer degrades to
    /// "starts when synthesis ends" rather than needing a second code path.
    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws
}

public extension TtsEngine {
    /// Non-streaming fallback: the whole utterance delivered as a single chunk once it exists.
    func synthesizeStreaming(text: String, voice: String?, language: String?,
                             onChunk: @escaping @Sendable (SynthesizedSpeechChunk) -> Bool) async throws {
        let speech = try await synthesize(text: text, voice: voice, language: language)
        _ = onChunk(SynthesizedSpeechChunk(samples: speech.samples, sampleRate: speech.sampleRate))
    }
}
