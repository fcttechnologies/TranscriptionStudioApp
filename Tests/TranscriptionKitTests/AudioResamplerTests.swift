// AudioResampler is the pipeline chokepoint every capture path (mic, meeting, file ingest)
// funnels through before ASR/diarization ever see a sample — every capture source's input
// format is device/OS-dependent, so this is the seam that must convert correctly no matter
// what arrives. Unit-tests the format fast-path, real resampling via AVAudioConverter (rate
// change, channel downmix, non-float sample formats), converter caching/rebuild across a
// format change, and degenerate (empty/tiny) buffers.

import AVFoundation
import Testing
@testable import TranscriptionKit

@Suite("AudioResampler")
struct AudioResamplerTests {

    /// Builds a PCM buffer of `frameCount` frames in the given format, filled with a simple
    /// deterministic ramp/tone so the samples are non-zero and distinguishable.
    private func makeBuffer(format: AVAudioFormat, frameCount: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = Int(format.channelCount)

        if format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            for channel in 0..<channels {
                for frame in 0..<frameCount {
                    data[channel][frame] = Float(sin(2 * .pi * 220 * Double(frame) / format.sampleRate)) * 0.5
                }
            }
        } else if format.commonFormat == .pcmFormatInt16, let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                for frame in 0..<frameCount {
                    let sample = sin(2 * .pi * 220 * Double(frame) / format.sampleRate) * 0.5
                    data[channel][frame] = Int16(sample * Double(Int16.max))
                }
            }
        }
        return buffer
    }

    // MARK: - Fast path

    @Test func alreadyCanonicalFormatSkipsConversionAndReturnsExactSamples() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let buffer = makeBuffer(format: format, frameCount: 800)
        let expected = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 800))

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)

        #expect(out.count == 800)
        #expect(out == expected)
    }

    // MARK: - Real conversion

    @Test func differentSampleRateResamplesToCanonicalRate() {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                        channels: 1, interleaved: false)!
        // 0.1s of audio at 44.1kHz -> should resample to ~0.1s at 16kHz.
        let buffer = makeBuffer(format: inputFormat, frameCount: 4_410)

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)

        // Allow slack for the converter's internal framing, but it must land near 1,600 samples.
        #expect(!out.isEmpty)
        #expect(abs(out.count - 1_600) < 200)
        // Real energy came through — not a silent/garbage buffer.
        #expect(out.contains { abs($0) > 0.05 })
    }

    @Test func stereoInputDownmixesToMono() {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 2, interleaved: false)!
        let buffer = makeBuffer(format: inputFormat, frameCount: 1_600)

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)

        #expect(!out.isEmpty)
        // Same sample rate, so the frame count should be close to the input's.
        #expect(abs(out.count - 1_600) < 200)
        #expect(out.contains { abs($0) > 0.05 })
    }

    @Test func nonFloatSampleFormatConvertsThroughTheConverterPath() {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: false)!
        let buffer = makeBuffer(format: inputFormat, frameCount: 1_600)

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)

        #expect(!out.isEmpty)
        #expect(out.contains { abs($0) > 0.05 })
    }

    /// The converter is cached per input format and rebuilt when the format changes — feeding
    /// two different formats through the same resampler instance must succeed both times
    /// (exercises both the initial build and the rebuild-on-change branch).
    @Test func converterIsRebuiltWhenTheInputFormatChanges() {
        let formatA = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                    channels: 1, interleaved: false)!
        let formatB = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                    channels: 2, interleaved: false)!
        let bufferA = makeBuffer(format: formatA, frameCount: 4_410)
        let bufferB = makeBuffer(format: formatB, frameCount: 4_800)

        let resampler = AudioResampler()
        let outA = resampler.resample(bufferA)
        let outB = resampler.resample(bufferB)
        // Feeding formatA again reuses/rebuilds correctly a second time.
        let outA2 = resampler.resample(bufferA)

        #expect(!outA.isEmpty)
        #expect(!outB.isEmpty)
        #expect(!outA2.isEmpty)
        #expect(abs(outA.count - 1_600) < 200)
        #expect(abs(outB.count - 1_600) < 300)
    }

    // MARK: - Degenerate buffers

    @Test func emptyBufferResamplesToEmptyWithoutCrashing() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0)!
        buffer.frameLength = 0

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)
        #expect(out.isEmpty)
    }

    @Test func tinyBufferBelowOneOutputFrameStillCompletesWithoutCrashing() {
        // A handful of samples at a rate needing downsampling — the smallest realistic case.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 1, interleaved: false)!
        let buffer = makeBuffer(format: format, frameCount: 4)

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)
        // Either an empty result or a couple of converted samples — must not crash either way.
        #expect(out.count >= 0)
    }

    @Test func canonicalFastPathOnEmptyBufferReturnsEmpty() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0)!
        buffer.frameLength = 0

        let resampler = AudioResampler()
        let out = resampler.resample(buffer)
        #expect(out.isEmpty)
    }
}
