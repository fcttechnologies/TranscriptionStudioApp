import Foundation

/// The wire format for *streamed* synthesis: a canonical 16-bit mono PCM WAV whose header
/// carries the unknown-length sentinel (`0xFFFFFFFF`) in both size fields, followed by raw
/// little-endian samples as they are produced.
///
/// The sentinel is the established convention for a WAV written to an unseekable output
/// (`ffmpeg -f wav pipe:` writes exactly this), and Apple's own stack — `afplay`,
/// `AVAudioFile`, `AVAudioPlayer` — reads such a file by clamping to the actual byte count,
/// reporting the true frame count and duration (verified empirically on macOS 27). A consumer
/// therefore treats the data as "read to end of stream", which is precisely what a streaming
/// body means. `SynthesizedSpeech.wavData()` remains the format for *complete* files, whose
/// header sizes are known and written honestly.
enum StreamingWav {
    /// The 44-byte canonical PCM WAV header for 16-bit mono audio at `sampleRate`, with the
    /// RIFF and `data` chunk sizes set to the unknown-length sentinel.
    static func header(sampleRate: Int) -> Data {
        let bytesPerFrame = 2  // 16-bit mono
        var data = Data(capacity: 44)
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&data, 0xFFFF_FFFF)                       // RIFF size: unknown
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&data, 16)                                // fmt chunk size
        appendUInt16(&data, 1)                                 // PCM
        appendUInt16(&data, 1)                                 // mono
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * bytesPerFrame))  // byte rate
        appendUInt16(&data, UInt16(bytesPerFrame))             // block align
        appendUInt16(&data, 16)                                // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(&data, 0xFFFF_FFFF)                       // data size: unknown
        return data
    }

    /// Float samples in [-1, 1] as raw 16-bit little-endian PCM — the incremental encoding a
    /// stream needs, where `AVAudioFile` (which must own a whole file) can't serve.
    static func pcm16Data(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            appendInt16(&data, Int16((clamped * 32767).rounded()))
        }
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt16(_ data: inout Data, _ value: Int16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
