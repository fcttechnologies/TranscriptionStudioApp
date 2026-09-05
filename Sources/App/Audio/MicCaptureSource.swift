// MicCaptureSource — microphone capture via AVAudioEngine on both platforms. The simple "room"
// path (his voice + room / speakerphone). Taps the input node, resamples every buffer to the
// AudioChunk currency (16 kHz mono Float32), and stamps session-relative times. iOS additionally
// configures the AVAudioSession and requests record permission. Archival is the controller's job
// (it writes the session WAV from the mixed archive buffer), so this source doesn't write a file.

import AVFoundation
import FCTCore
import Foundation

enum MicCaptureError: Error, LocalizedError {
    case permissionDenied
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone permission denied"
        case .engineStartFailed(let m): "Audio engine failed to start: \(m)"
        }
    }
}

final class MicCaptureSource: CaptureSource, @unchecked Sendable {
    let chunks: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation

    private let track: AudioTrack
    private let sessionID: UUID
    private let recorder: PipelineRecorder?

    private let engine = AVAudioEngine()
    /// Resampler + lock-guarded sample counter, held together so the `@Sendable` audio tap block
    /// (`installAudioTap`, iOS/macOS 27) captures one Sendable value, not non-Sendable state.
    private let tapState = TapState()

    /// - Parameter track: how emitted chunks are tagged (mic path is `.mixed` by default; in a
    ///   meeting the mic is the local user, tagged `.microphone`).
    init(track: AudioTrack = .mixed, sessionID: UUID = UUID(), recorder: PipelineRecorder? = nil) {
        self.track = track
        self.sessionID = sessionID
        self.recorder = recorder
        (chunks, continuation) = AsyncThrowingStream.makeStream()
    }

    func start() async throws {
        guard await Self.requestPermission() else { throw MicCaptureError.permissionDenied }
        try configureSession()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // Emit into locals so the @Sendable tap block captures no `self`.
        let continuation = self.continuation
        let tapState = self.tapState
        let track = self.track
        let recorder = self.recorder
        let sessionID = self.sessionID

        // iOS/macOS 27: installAudioTap's block is @Sendable and hands read-only, Sendable buffers.
        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: inputFormat) { readOnly, _ in
            guard let buffer = Self.mutableCopy(of: readOnly) else { return }
            let samples = tapState.resampler.resample(buffer)
            guard !samples.isEmpty else { return }
            let startSample = tapState.reserve(samples.count)
            let startTime = Double(startSample) / AudioChunk.sampleRate
            continuation.yield(AudioChunk(track: track, samples: samples, startTime: startTime))
            recorder?.record(PipelineEvent(
                sessionID: sessionID, stage: .capture, level: .debug, message: "mic buffer",
                metadata: ["samples": "\(samples.count)", "t": Format.fixed(startTime, decimals: 2)]))
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

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        continuation.finish()
        recorder?.record(PipelineEvent(sessionID: sessionID, stage: .capture, message: "mic capture stopped"))
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: tap state + buffer bridging

    /// Per-tap mutable state. `@unchecked Sendable`: `installAudioTap`'s block is `@Sendable`, but
    /// it fires serially on the audio render thread and the running-sample counter is lock-guarded,
    /// so this is never touched concurrently.
    private final class TapState: @unchecked Sendable {
        let resampler = AudioResampler()
        private let lock = NSLock()
        private var emitted = 0
        /// Reserve `count` sample slots; returns the session-relative start sample index.
        func reserve(_ count: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let start = emitted
            emitted += count
            return start
        }
    }

    /// Copy a read-only tap buffer (`installAudioTap`'s Sendable buffer) into a mutable
    /// `AVAudioPCMBuffer` the resampler + its `AVAudioConverter` can consume — a byte-for-byte
    /// `AudioBufferList` copy, so any channel layout / sample type carries over unchanged.
    private static func mutableCopy(of readOnly: AVReadOnlyAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(readOnly.frameLength)
        guard let out = AVAudioPCMBuffer(pcmFormat: readOnly.format,
                                         frameCapacity: frames) else { return nil }
        out.frameLength = frames
        // Safety: both lists are the buffers' own C audio-buffer tables, valid for the closure
        // (`readOnly` is alive for the call and `out` is retained here); the copy is bounded by
        // the smaller of the two byte counts and the source is only read.
        unsafe readOnly.withUnsafeAudioBufferList { srcList in
            let src = unsafe UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: srcList))
            let dst = unsafe UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
            for i in 0..<Swift.min(src.count, dst.count) {
                guard let s = unsafe src[i].mData, let d = unsafe dst[i].mData else { continue }
                unsafe memcpy(d, s, Int(Swift.min(src[i].mDataByteSize, dst[i].mDataByteSize)))
            }
        }
        return out
    }

    // MARK: platform specifics

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothHFP, .defaultToSpeaker])
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
