import Foundation

/// Which capture path a buffer came from. Attribution depends on it: in meeting mode the
/// microphone track is the local user ("Me") and the system track is everyone else.
enum AudioTrack: String, Sendable, Codable, Hashable {
    case microphone
    case system
    /// A single-track source (file ingest, room recording) with no track separation.
    case mixed
}

/// The one audio currency every engine speaks: 16 kHz mono Float32 samples with a
/// session-relative start time. Converters normalize to this at the capture/ingest
/// boundary so ASR and diarization never see device formats.
struct AudioChunk: Sendable {
    static let sampleRate: Double = 16_000

    let track: AudioTrack
    let samples: [Float]
    /// Seconds since the session started (derived from host time at the capture boundary,
    /// so mic and system chunks are directly comparable).
    let startTime: TimeInterval

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    var endTime: TimeInterval { startTime + duration }

    init(track: AudioTrack, samples: [Float], startTime: TimeInterval) {
        self.track = track
        self.samples = samples
        self.startTime = startTime
    }
}

/// A live audio source (mic, meeting, mock). `start()` begins delivery into `chunks`;
/// the stream finishes on `stop()` and throws on capture failure.
protocol CaptureSource: AnyObject, Sendable {
    /// Single-consumption stream of normalized chunks.
    var chunks: AsyncThrowingStream<AudioChunk, Error> { get }
    func start() async throws
    func stop() async
}
