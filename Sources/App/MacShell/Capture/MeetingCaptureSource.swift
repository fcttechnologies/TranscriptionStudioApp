// MeetingCaptureSource — the true "record a meeting" path on macOS. One SCStream captures system
// audio AND the microphone as two separately-attributed tracks on one shared clock, so a Zoom/Meet
// call is diarized (remote voices) with the local user free-attributed as "Me". Both tracks are
// resampled to the AudioChunk currency and emitted into the single `chunks` stream, tagged
// `.system` / `.microphone`; SCRecordingOutput archives an un-mixed two-track file for offline replay.
//
// Screen Recording is a TCC-gated permission with a well-known quirk: the FIRST grant only takes
// effect after the app restarts. That, and denial, are surfaced as typed `MeetingCaptureState` so
// the UI can explain them (and deep-link to Settings) rather than failing opaquely.

#if os(macOS)
import AVFoundation
import CoreMedia
import FCTCore
import Foundation
import ScreenCaptureKit

/// What the meeting capture needs from the user / OS, for the UI to explain.
enum MeetingCaptureState: Sendable, Equatable {
    case idle
    case capturing
    case stopped
    /// Screen Recording permission not yet granted — request it.
    case needsScreenRecordingPermission
    /// Permission was just granted for the first time; macOS requires an app restart to use it.
    case restartRequiredAfterGrant
    /// Permission denied — send the user to System Settings.
    case screenRecordingDenied(settingsURL: URL)

    /// Deep link to System Settings › Privacy & Security › Screen Recording.
    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

enum MeetingCaptureError: Error, LocalizedError {
    case permission(MeetingCaptureState)
    case noDisplay
    case streamStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .permission(let s): "Screen recording unavailable: \(s)"
        case .noDisplay: "No display available to capture"
        case .streamStartFailed(let m): "Meeting capture failed to start: \(m)"
        }
    }
}

final class MeetingCaptureSource: NSObject, CaptureSource, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    let chunks: AsyncThrowingStream<AudioChunk, Error>
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation

    private let sessionID: UUID
    private let recorder: PipelineRecorder?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let outputQueue = DispatchQueue(label: "com.fcttechnologies.meeting.capture")
    private let systemResampler = AudioResampler()
    private let micResampler = AudioResampler()

    private let lock = NSLock()
    private var firstPTS: CMTime?     // shared session clock origin across both tracks
    private var _state: MeetingCaptureState = .idle   // guarded by `lock`

    /// Capture state. Written from the MainActor-driven start()/stop() AND from SCStream's own
    /// delegate thread (stream(_:didStopWithError:)); every access is serialized by `lock`, so a
    /// torn read of the enum's associated `settingsURL` value can't occur.
    var state: MeetingCaptureState { lock.withLock { _state } }

    private func setState(_ newValue: MeetingCaptureState) {
        lock.withLock { _state = newValue }
    }

    init(sessionID: UUID = UUID(), recorder: PipelineRecorder? = nil) {
        self.sessionID = sessionID
        self.recorder = recorder
        (chunks, continuation) = AsyncThrowingStream.makeStream()
        super.init()
    }

    /// The two-track archival file (system + mic, un-mixed).
    var archiveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TranscriptionStudio/Audio/\(sessionID.uuidString).mov")
    }

    func start() async throws {
        // TCC: preflight, then request. A fresh grant needs an app restart to take effect.
        if !CGPreflightScreenCaptureAccess() {
            setState(.needsScreenRecordingPermission)
            let granted = CGRequestScreenCaptureAccess()
            if granted {
                setState(.restartRequiredAfterGrant)
                throw MeetingCaptureError.permission(state)
            } else {
                setState(.screenRecordingDenied(settingsURL: MeetingCaptureState.screenRecordingSettingsURL))
                throw MeetingCaptureError.permission(state)
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            setState(.screenRecordingDenied(settingsURL: MeetingCaptureState.screenRecordingSettingsURL))
            throw MeetingCaptureError.permission(state)
        }
        guard let display = content.displays.first else { throw MeetingCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true          // don't record our own playback
        config.sampleRate = Int(AudioChunk.sampleRate)      // request 16k (defensively re-convert anyway)
        config.channelCount = 1
        // Audio-first: keep the video path minimal (SCK requires a display filter regardless).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)

        // Un-mixed two-track archival (system + mic on separate tracks).
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = archiveURL
        recConfig.outputFileType = .mov
        recConfig.mixesAudioWithMicrophone = false
        try? FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: self)
        try? stream.addRecordingOutput(recOutput)
        self.recordingOutput = recOutput

        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            continuation.finish(throwing: MeetingCaptureError.streamStartFailed(error.localizedDescription))
            throw MeetingCaptureError.streamStartFailed(error.localizedDescription)
        }
        setState(.capturing)
        recorder?.record(PipelineEvent(sessionID: sessionID, stage: .capture,
                                       message: "meeting capture started (system + mic)"))
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        recordingOutput = nil
        continuation.finish()
        setState(.stopped)
        recorder?.record(PipelineEvent(sessionID: sessionID, stage: .capture, message: "meeting capture stopped"))
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        let track: AudioTrack
        let resampler: AudioResampler
        switch type {
        case .audio: track = .system; resampler = systemResampler
        case .microphone: track = .microphone; resampler = micResampler
        default: return   // ignore .screen video
        }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.resample(pcm)
        guard !samples.isEmpty else { return }

        // Shared session clock: both tracks stamped relative to the first PTS seen on either.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lock.lock()
        if firstPTS == nil { firstPTS = pts }
        let origin = firstPTS ?? pts
        lock.unlock()
        let startTime = max(0, (pts - origin).seconds)

        continuation.yield(AudioChunk(track: track, samples: samples, startTime: startTime))
        recorder?.record(PipelineEvent(
            sessionID: sessionID, stage: .capture, level: .debug, message: "\(track.rawValue) buffer",
            metadata: ["samples": "\(samples.count)", "t": Format.fixed(startTime, decimals: 2)]))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
        setState(.stopped)
        recorder?.record(PipelineEvent(sessionID: sessionID, stage: .capture, level: .error,
                                       message: "meeting stream stopped with error",
                                       metadata: ["error": error.localizedDescription]))
    }

    // MARK: helpers

    /// CMSampleBuffer (audio) -> AVAudioPCMBuffer in the buffer's own format.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Safety: the stream description pointer is owned by `formatDesc`, which outlives the
        // `AVAudioFormat` init that reads it here.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = unsafe CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let format = unsafe AVAudioFormat(streamDescription: asbdPtr) else {
            return nil
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        // Safety: `pcm` was allocated for exactly `frames` frames of this format, and its buffer
        // list is its own; the copy writes at most that many.
        let status = unsafe CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
#endif
