import AVFoundation
import Foundation

/// Encodes and decodes the app's one audio currency (16 kHz mono Float32) as compressed
/// AAC/m4a `Data`, so any session's recording is archived and stays re-playable — the offline
/// verification loop. The bytes are authored, so they leave the row for the blob layer at the
/// next staging sweep (`TranscriptionSync`); ~32 kbps mono is what makes the egress arithmetic
/// on `TranscriptSession.audioAsset` come out where it does. Also synthesizes demo audio when
/// no capture hardware ran.
public enum AudioFileIO {
    /// 16 kHz mono Float32 — the same contract `AudioChunk` speaks.
    public static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: AudioChunk.sampleRate,
                      channels: 1,
                      interleaved: false)!
    }

    /// AAC-in-m4a encoder settings — ~32 kbps mono at 16 kHz. Plenty for speech, and ~20×
    /// smaller than the equivalent Float32 WAV.
    private static var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVSampleRateKey: AudioChunk.sampleRate,
         AVNumberOfChannelsKey: 1,
         AVEncoderBitRateKey: 32_000]
    }

    /// Encode mono float samples (16 kHz) to AAC/m4a `Data`. `AVAudioFile` only writes to a
    /// URL, so we encode to a temp `.m4a`, close the file to finalize the container, then read
    /// it back into memory.
    public static func encodeAAC(samples: [Float]) throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            // Scope the AVAudioFile so it deallocates — and finalizes the m4a container —
            // before we read the bytes back. Writing float buffers; the file encodes to AAC.
            let file = try AVAudioFile(forWriting: tempURL, settings: aacSettings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channel = buffer.floatChannelData?[0], !samples.isEmpty {
                samples.withUnsafeBufferPointer { src in
                    channel.update(from: src.baseAddress!, count: samples.count)
                }
            }
            try file.write(from: buffer)
        }
        return try Data(contentsOf: tempURL)
    }

    /// Decode AAC/m4a `Data` back to 16 kHz mono float samples (for re-processing an archived
    /// session offline). Playback reads the `Data` directly via `AVAudioPlayer(data:)`.
    public static func decodeAAC(_ data: Data) throws -> [Float] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL)
        let file = try AVAudioFile(forReading: tempURL,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Synthesize a distinct tone per speaker turn so seeking to a segment is *audible* — a
    /// pitch shift you can hear when you click a turn. Purely a demo aid for seeded sessions.
    public static func synthesize(turns: [(start: TimeInterval, end: TimeInterval, slot: Int)],
                                  totalDuration: TimeInterval) -> [Float] {
        let sampleRate = AudioChunk.sampleRate
        let count = Int(totalDuration * sampleRate)
        guard count > 0 else { return [] }
        // A pentatonic spread so speaker tones sit pleasantly apart.
        let toneForSlot: [Double] = [196, 261.63, 329.63, 392]
        var samples = [Float](repeating: 0, count: count)
        for turn in turns {
            let startSample = max(Int(turn.start * sampleRate), 0)
            let endSample = min(Int(turn.end * sampleRate), count)
            guard startSample < endSample else { continue }
            let freq = toneForSlot[max(0, turn.slot) % toneForSlot.count]
            for index in startSample..<endSample {
                let t = Double(index) / sampleRate
                let local = Double(index - startSample) / sampleRate
                // Gentle attack/decay envelope so turn edges don't click.
                let turnLength = Double(endSample - startSample) / sampleRate
                let envelope = min(1, min(local, turnLength - local) / 0.05)
                samples[index] = Float(sin(2 * .pi * freq * t) * 0.18 * max(0, envelope))
            }
        }
        return samples
    }
}
