// Audio conversion helpers shared by the capture sources: everything normalizes to the
// AudioChunk currency (16 kHz mono Float32) at the capture boundary. Session archival is owned
// by the recording controller (it writes one WAV from the mixed archive buffer via AudioFileIO).

import AVFoundation
import Foundation

/// The canonical processing format: 16 kHz mono Float32 (non-interleaved).
enum CanonicalAudio {
    static let sampleRate = AudioChunk.sampleRate   // 16_000

    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: 1,
                      interleaved: false)!
    }
}

/// Converts arbitrary-format PCM buffers to 16 kHz mono Float32 samples. One resampler per input
/// format (the converter is created lazily and reused; a format change rebuilds it).
public final class AudioResampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = CanonicalAudio.format

    public init() {}

    /// Resample one input buffer to a flat `[Float]` of 16 kHz mono samples.
    public func resample(_ input: AVAudioPCMBuffer) -> [Float] {
        let inFormat = input.format
        if inFormat.sampleRate == outputFormat.sampleRate,
           inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32 {
            return Self.floats(from: input)
        }
        if converter == nil || inputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outputFormat)
            inputFormat = inFormat
        }
        guard let converter else { return [] }

        let ratio = outputFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { return [] }
        return Self.floats(from: output)
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
    }
}
