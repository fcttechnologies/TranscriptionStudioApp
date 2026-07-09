import Foundation

/// Which capture path a buffer came from. Attribution depends on it: in meeting mode the
/// microphone track is the local user ("Me") and the system track is everyone else.
public enum AudioTrack: String, Sendable, Codable, Hashable {
    case microphone
    case system
    /// A single-track source (file ingest, room recording) with no track separation.
    case mixed
}

/// The one audio currency every engine speaks: 16 kHz mono Float32 samples with a
/// session-relative start time. Converters normalize to this at the capture/ingest
/// boundary so ASR and diarization never see device formats.
public struct AudioChunk: Sendable {
    public static let sampleRate: Double = 16_000

    public let track: AudioTrack
    public let samples: [Float]
    /// Seconds since the session started (derived from host time at the capture boundary,
    /// so mic and system chunks are directly comparable).
    public let startTime: TimeInterval

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var endTime: TimeInterval { startTime + duration }

    public init(track: AudioTrack, samples: [Float], startTime: TimeInterval) {
        self.track = track
        self.samples = samples
        self.startTime = startTime
    }
}

/// A live audio source (mic, meeting, mock). `start()` begins delivery into `chunks`;
/// the stream finishes on `stop()` and throws on capture failure.
public protocol CaptureSource: AnyObject, Sendable {
    /// Single-consumption stream of normalized chunks.
    var chunks: AsyncThrowingStream<AudioChunk, Error> { get }
    func start() async throws
    func stop() async
}
