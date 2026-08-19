import Foundation
import Testing
@testable import TranscriptionKit

/// Covers the AAC codec that replaced on-disk WAV archiving: mono 16 kHz float samples
/// encode to compact m4a `Data` and decode back to playable samples, and the compression is
/// the big win (~20× smaller than the equivalent Float32 WAV) that makes the audio small
/// enough to archive and re-play, and to ride the blob layer as an authored recording.
@Suite("AudioFileIO — AAC codec")
struct AudioFileIOTests {

    /// One second of a 220 Hz sine at 16 kHz — a realistic, non-silent speech-band signal.
    private func sineSamples(seconds: Double = 1.0, frequency: Double = 220) -> [Float] {
        let rate = AudioChunk.sampleRate
        let count = Int(seconds * rate)
        return (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / rate) * 0.3) }
    }

    @Test func encodesToCompactDataAndDecodesBackToSamples() throws {
        let samples = sineSamples()
        let data = try AudioFileIO.encodeAAC(samples: samples)
        #expect(!data.isEmpty)

        let decoded = try AudioFileIO.decodeAAC(data)
        // AAC adds a little encoder priming/padding, so the count isn't identical — but it
        // round-trips to roughly the same length of real (non-silent) audio.
        #expect(decoded.count > samples.count / 2)
        let peak = decoded.map(abs).max() ?? 0
        #expect(peak > 0.05)
    }

    @Test func aacIsFarSmallerThanTheEquivalentWav() throws {
        let samples = sineSamples(seconds: 5)
        let data = try AudioFileIO.encodeAAC(samples: samples)

        // Float32 mono WAV: 4 bytes/sample + a 44-byte header.
        let wavBytes = samples.count * 4 + 44
        let ratio = Double(wavBytes) / Double(data.count)
        // ~20× is expected for 32 kbps AAC vs Float32 WAV; assert a conservative floor.
        #expect(ratio > 10)
    }

    @Test func encodesEmptySamplesWithoutCrashing() throws {
        let data = try AudioFileIO.encodeAAC(samples: [])
        // A valid (if tiny) m4a container is produced even with no audio.
        #expect(!data.isEmpty)
        let decoded = try AudioFileIO.decodeAAC(data)
        #expect(decoded.isEmpty || decoded.allSatisfy { abs($0) < 0.001 })
    }
}
