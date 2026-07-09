import Foundation
import Synchronization
import Testing
@testable import TranscriptionKit

/// The real spike: WhisperKit downloads/loads the platform default model and transcribes
/// real audio on this Mac. Set `TS_SKIP_MODEL_TESTS=1` to skip in offline/CI environments
/// (the model download needs network on first run; WhisperKit caches it after that).
@Suite("WhisperKitAsrEngine — real model integration", .serialized)
struct WhisperKitAsrEngineIntegrationTests {
    static var modelTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["TS_SKIP_MODEL_TESTS"] != "1"
    }

    static var testResourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WhisperKitAsrEngineIntegrationTests.swift
            .deletingLastPathComponent() // TranscriptionKitTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("TestResources")
    }

    // Full-buffer transcription of a real ~44s two-speaker clip through the real turbo
    // model: proves download → load → prewarm → transcribe end to end, with real
    // confidence fields, and reports timing/RTF for the lane report.
    @Test(.enabled(if: WhisperKitAsrEngineIntegrationTests.modelTestsEnabled))
    func transcribesRealAudioWithConfidences() async throws {
        let wav = Self.testResourcesDir.appendingPathComponent("two_speakers_short.wav")
        #expect(FileManager.default.fileExists(atPath: wav.path),
               "Run scripts/make-verification-audio.sh first")

        let engine = WhisperKitAsrEngine()

        let prepareClock = ContinuousClock()
        let prepareStart = prepareClock.now
        let lastPhase = Mutex("")
        try await engine.prepare(onProgress: { progress in
            lastPhase.withLock { $0 = progress.phase }
        })
        let prepareElapsed = prepareStart.duration(to: prepareClock.now)
        print("[spike] prepare() took \(prepareElapsed), last phase: \(lastPhase.withLock { $0 })")

        let samples = try loadWavAsFloatMono16k(wav)
        let audioSeconds = Double(samples.count) / AudioChunk.sampleRate

        let transcribeClock = ContinuousClock()
        let transcribeStart = transcribeClock.now
        let segments = try await engine.transcribe(samples: samples, track: .mixed, wordTimestamps: true)
        let transcribeElapsed = transcribeStart.duration(to: transcribeClock.now)
        let transcribeSeconds = Double(transcribeElapsed.components.seconds)
            + Double(transcribeElapsed.components.attoseconds) / 1e18
        let rtf = transcribeSeconds / audioSeconds
        print("[spike] transcribe() took \(transcribeElapsed) for \(audioSeconds)s audio — RTF \(rtf)")

        #expect(!segments.isEmpty)
        for segment in segments {
            #expect(segment.end > segment.start)
            #expect(!segment.text.isEmpty)
        }
        // Real Whisper confidence fields should be populated (not the zeroed defaults).
        #expect(segments.contains { $0.avgLogprob != 0 })
        // Word timestamps were requested — at least one segment should carry them.
        #expect(segments.contains { ($0.words?.isEmpty == false) })

        let fullText = segments.map(\.text).joined(separator: " ").lowercased()
        // The clip's ground-truth dialogue mentions "March" and "budget" — a loose
        // sanity check that real content came back, not silence/garbage.
        #expect(fullText.contains("march") || fullText.contains("budget") || fullText.contains("morning"))
    }

    // The streaming loop confirms text incrementally and finishes with a fully
    // confirmed transcript — verified against the same real model.
    @Test(.enabled(if: WhisperKitAsrEngineIntegrationTests.modelTestsEnabled))
    func streamsRealAudioToAConfirmedTranscript() async throws {
        let wav = Self.testResourcesDir.appendingPathComponent("two_speakers_short.wav")
        let samples = try loadWavAsFloatMono16k(wav)
        let engine = WhisperKitAsrEngine(minimumNewAudioSeconds: 3.0)
        try await engine.prepare(onProgress: { _ in })

        let chunkSeconds = 0.5
        let chunkSize = Int(AudioChunk.sampleRate * chunkSeconds)
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        Task {
            var offset = 0
            var elapsed: TimeInterval = 0
            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                continuation.yield(AudioChunk(track: .mixed, samples: Array(samples[offset..<end]), startTime: elapsed))
                elapsed += chunkSeconds
                offset = end
            }
            continuation.finish()
        }

        var lastUpdate: AsrUpdate?
        for try await update in engine.stream(chunks: stream) {
            lastUpdate = update
        }

        let final = try #require(lastUpdate)
        #expect(final.unconfirmed.isEmpty)
        #expect(!final.confirmed.isEmpty)
        let text = final.confirmed.map(\.text).joined(separator: " ")
        #expect(!text.isEmpty)
    }
}

/// Minimal WAV → 16k mono Float32 reader for the test (avoids depending on WhisperKit's
/// AVAudioFile path so this test exercises a plain sample array like a capture pipeline
/// would hand the engine).
private func loadWavAsFloatMono16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFileCompat(forReading: url)
    return file.floatSamples
}

import AVFoundation

private struct AVAudioFileCompat {
    let floatSamples: [Float]

    init(forReading url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try audioFile.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        floatSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
