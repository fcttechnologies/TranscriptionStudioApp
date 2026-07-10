// MicCaptureSource — microphone capture via AVAudioEngine on both platforms. The simple "room"
// path (his voice + room / speakerphone). Taps the input node, resamples every buffer to the
// AudioChunk currency (16 kHz mono Float32), and stamps session-relative times. iOS additionally
// configures the AVAudioSession and requests record permission. Archival is the controller's job
// (it writes the session WAV from the mixed archive buffer), so this source doesn't write a file.

import AVFoundation
import Foundation

public enum MicCaptureError: Error, LocalizedError {
    case permissionDenied
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone permission denied"
        case .engineStartFailed(let m): "Audio engine failed to start: \(m)"
        }
    }
}

public final class MicCaptureSource: CaptureSource, @unchecked Sendable {
    public let chunks: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation

    private let track: AudioTrack
    private let sessionID: UUID
    private let recorder: PipelineRecorder?

    private let engine = AVAudioEngine()
    private let resampler = AudioResampler()

    private let lock = NSLock()
    private var emittedSamples: Int = 0    // for session-relative timestamps

    /// - Parameter track: how emitted chunks are tagged (mic path is `.mixed` by default; in a
    ///   meeting the mic is the local user, tagged `.microphone`).
    public init(track: AudioTrack = .mixed, sessionID: UUID = UUID(), recorder: PipelineRecorder? = nil) {
        self.track = track
        self.sessionID = sessionID
        self.recorder = recorder
        (chunks, continuation) = AsyncThrowingStream.makeStream()
    }

    public func start() async throws {
        guard await Self.requestPermission() else { throw MicCaptureError.permissionDenied }
        try configureSession()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // Emit into locals so the realtime tap closure captures no `self` methods.
        let continuation = self.continuation
        let resampler = self.resampler
        let track = self.track
        let lock = self.lock
        let recorder = self.recorder
        let sessionID = self.sessionID
        // A box for the mutable running-sample counter, guarded by `lock`.
        let counter = Counter()
        self.counterRef = counter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let samples = resampler.resample(buffer)
            guard !samples.isEmpty else { return }
            lock.lock()
            let startSample = counter.value
            counter.value += samples.count
            lock.unlock()
            let startTime = Double(startSample) / AudioChunk.sampleRate
            continuation.yield(AudioChunk(track: track, samples: samples, startTime: startTime))
            recorder?.record(PipelineEvent(
                sessionID: sessionID, stage: .capture, level: .debug, message: "mic buffer",
                metadata: ["samples": "\(samples.count)", "t": String(format: "%.2f", startTime)]))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish(throwing: MicCaptureError.engineStartFailed(error.localizedDescription))
            throw MicCaptureError.engineStartFailed(error.localizedDescription)
        }
        recorder?.record(PipelineEvent(
            sessionID: sessionID, stage: .capture, message: "mic capture started",
            metadata: ["inputRate": "\(Int(inputFormat.sampleRate))", "track": track.rawValue]))
    }

    public func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        continuation.finish()
        recorder?.record(PipelineEvent(sessionID: sessionID, stage: .capture, message: "mic capture stopped"))
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // Retains the counter box for the tap's lifetime.
    private var counterRef: Counter?

    private final class Counter { var value: Int = 0 }

    // MARK: platform specifics

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func requestPermission() async -> Bool {
        #if os(iOS)
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }
}
