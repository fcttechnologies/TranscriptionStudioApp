// StreamingWav — the streamed-synthesis wire format. The header is pinned field by field
// (a parser reads these bytes, not our intentions), and the sample conversion is pinned on
// exact values including clamping. The "Apple's stack accepts the sentinel" premise is proven
// by decoding a sentinel-headed file with AVAudioFile right here, not assumed.

import AVFoundation
import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("StreamingWav — unknown-length WAV for streamed synthesis")
struct StreamingWavTests {
    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        littleEndian(data, at: offset)
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        littleEndian(data, at: offset)
    }

    /// The little-endian integer at `offset`, assembled by shifts: the inverse of what the
    /// writer does, and no pointer over the bytes.
    private func littleEndian<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        var value: T = 0
        for i in stride(from: T.bitWidth / 8 - 1, through: 0, by: -1) {
            value = (value << 8) | T(truncatingIfNeeded: data[data.startIndex + offset + i])
        }
        return value
    }

    @Test func headerCarriesTheCanonicalFieldsAndTheUnknownLengthSentinel() {
        let header = StreamingWav.header(sampleRate: 24_000)

        #expect(header.count == 44)
        #expect(header.prefix(4) == Data("RIFF".utf8))
        #expect(uint32(header, at: 4) == 0xFFFF_FFFF)          // RIFF size: unknown
        #expect(header.subdata(in: 8..<16) == Data("WAVEfmt ".utf8))
        #expect(uint32(header, at: 16) == 16)                  // fmt chunk size
        #expect(uint16(header, at: 20) == 1)                   // PCM
        #expect(uint16(header, at: 22) == 1)                   // mono
        #expect(uint32(header, at: 24) == 24_000)              // sample rate
        #expect(uint32(header, at: 28) == 48_000)              // byte rate (16-bit mono)
        #expect(uint16(header, at: 32) == 2)                   // block align
        #expect(uint16(header, at: 34) == 16)                  // bits per sample
        #expect(header.subdata(in: 36..<40) == Data("data".utf8))
        #expect(uint32(header, at: 40) == 0xFFFF_FFFF)         // data size: unknown
    }

    @Test func pcm16ConvertsScalesAndClampsExactly() {
        let data = StreamingWav.pcm16Data([0, 1, -1, 0.5, 2.0, -3.0])

        #expect(data.count == 12)
        let values: [Int16] = (0..<6).map { index in littleEndian(data, at: index * 2) }
        #expect(values[0] == 0)
        #expect(values[1] == 32767)
        #expect(values[2] == -32767)
        #expect(values[3] == 16384)     // 0.5 * 32767 rounded
        #expect(values[4] == 32767)     // clamped
        #expect(values[5] == -32767)    // clamped
    }

    /// The design's load-bearing premise: a saved sentinel-headed stream decodes in Apple's own
    /// (strictest common) parser with the true frame count — a read-to-EOF client that saves the
    /// body gets a playable file.
    @Test func aSavedSentinelStreamDecodesWithTheTrueLength() throws {
        let sampleRate = 24_000
        let samples = (0..<sampleRate).map { Float(sin(2 * .pi * 220 * Double($0) / Double(sampleRate))) * 0.3 }
        var file = StreamingWav.header(sampleRate: sampleRate)
        file.append(StreamingWav.pcm16Data(samples))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-wav-test-\(UUID().uuidString).wav")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try AVAudioFile(forReading: url)
        #expect(decoded.length == AVAudioFramePosition(samples.count))
        #expect(decoded.processingFormat.sampleRate == Double(sampleRate))
        #expect(decoded.processingFormat.channelCount == 1)
    }
}
