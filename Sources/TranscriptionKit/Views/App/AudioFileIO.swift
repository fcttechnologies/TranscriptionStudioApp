import AVFoundation
import Foundation

/// Reads and writes the app's one audio currency (16 kHz mono Float32) as WAV files under
/// the app's audio directory, so any session's audio is archived and re-playable — the
/// offline verification loop. Also synthesizes demo audio when no capture hardware ran.
public enum AudioFileIO {
    /// 16 kHz mono Float32 — the same contract `AudioChunk` speaks.
    public static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: AudioChunk.sampleRate,
                      channels: 1,
                      interleaved: false)!
    }

    /// The directory archived session audio lives in (created on first use).
    public static func audioDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = base.appendingPathComponent("TranscriptionStudio/Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func url(forFileName name: String) -> URL? {
        (try? audioDirectory())?.appendingPathComponent(name)
    }

    /// Write mono float samples to a WAV file in the audio directory. Returns the file name.
    @discardableResult
    public static func writeWAV(samples: [Float], fileName: String) throws -> String {
        let url = try audioDirectory().appendingPathComponent(fileName)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
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
        return fileName
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
