import AVFoundation
import FCTComponentsUI
import Foundation
import Observation
import Synchronization

/// Speaks a transcript aloud with the on-device synthesis engine, streaming: the engine hands
/// over ~80 ms of audio per generation step through the `TtsEngine` streaming seam, each chunk
/// is scheduled onto an `AVAudioPlayerNode`, and the voice starts once a small lead is
/// buffered — within a moment of the tap, not when the whole transcript has been synthesized.
///
/// **Long transcripts.** The text is cut into sentence-aligned passages
/// (`TranscriptSpeech.passages`) synthesized strictly one at a time, each passage's audio
/// scheduled and then let go — so a transcript of any length holds about one passage of audio
/// in memory, and the passage loop throttles synthesis to at most `maxLeadSeconds` ahead of
/// the playhead instead of racing to the end. Pause holds the player *and* (at the next
/// passage boundary) the synthesis pipeline, so a paused reading isn't quietly burning
/// compute; stop takes effect immediately at any length.
///
/// The read-aloud counterpart of `PlaybackController`, sharing the mini-player with it;
/// `AppModel` keeps the two (and recording) mutually exclusive. The synthesis model (~1 GB
/// resident) is created per reading and released when the reading ends, so the footprint
/// exists only while a voice is actually speaking.
@MainActor
@Observable
public final class ReadAloudController {
    /// What's being spoken, for the mini-player.
    public struct NowSpeaking: Equatable, Sendable {
        public let sessionID: UUID
        public let title: String
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Model download/load and the first moments of synthesis, before audio starts.
        case preparing(phase: String, fraction: Double?)
        case speaking
        case paused
    }

    /// How much audio must be buffered before the voice starts (a smaller lead starts faster
    /// but risks a gap if a generation step runs slow), and how far synthesis may run ahead
    /// of the playhead before the passage loop waits.
    static let startLeadSeconds: TimeInterval = 0.6
    static let maxLeadSeconds: TimeInterval = 45

    public private(set) var phase: Phase = .idle
    public private(set) var nowSpeaking: NowSpeaking?

    /// Whether the mini-player should show the speaking pill.
    public var isActive: Bool { phase != .idle }

    @ObservationIgnored private let makeEngine: @Sendable () -> any TtsEngine
    @ObservationIgnored private var engine: (any TtsEngine)?
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var playerNode: AVAudioPlayerNode?
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    /// The current reading's cross-thread state. `speak` swaps in a fresh one, so a stale
    /// callback from a cancelled reading can never touch the new reading.
    @ObservationIgnored private var wire = SpeakWire()

    public init(makeEngine: @escaping @Sendable () -> any TtsEngine = { TTSKitTtsEngine() }) {
        self.makeEngine = makeEngine
    }

    // MARK: - Transport

    /// Speak a session's transcript from the beginning. Restarts if something (even the same
    /// session) is already speaking.
    public func speak(session: TranscriptSession) {
        let turns = TranscriptTurn.group(stored: session.segments ?? [])
        speak(sessionID: session.id, title: session.title, text: TranscriptSpeech.text(for: turns))
    }

    /// The text-level entry `speak(session:)` rides on. A no-op for empty text.
    public func speak(sessionID: UUID, title: String, text: String) {
        let passages = TranscriptSpeech.passages(from: text)
        guard !passages.isEmpty else { return }
        stop()

        nowSpeaking = NowSpeaking(sessionID: sessionID, title: title)
        phase = .preparing(phase: "Preparing the voice…", fraction: nil)
        let wire = SpeakWire()
        self.wire = wire
        let engine = makeEngine()
        self.engine = engine

        speakTask = Task { [weak self] in
            await self?.run(passages: passages, engine: engine, wire: wire)
        }
    }

    /// Pause or resume the voice. Resuming picks up exactly where it left off.
    public func togglePause() {
        switch phase {
        case .speaking:
            playerNode?.pause()
            wire.setPaused(true)
            phase = .paused
        case .paused:
            do {
                try playerNode?.playAudio()
            } catch {
                ToastCenter.shared.show(.speakFailed(error.localizedDescription))
                stop()
                return
            }
            wire.setPaused(false)
            phase = .speaking
        case .idle, .preparing:
            break
        }
    }

    /// Stop speaking entirely: cancel the synthesis, drop the scheduled audio, release the
    /// model and the audio graph. The mini-player pill disappears with it.
    public func stop() {
        wire.cancel()
        speakTask?.cancel()
        speakTask = nil
        teardownPlayback()
        engine = nil
        phase = .idle
        nowSpeaking = nil
    }

    // MARK: - The reading

    private func run(passages: [String], engine: any TtsEngine, wire: SpeakWire) async {
        do {
            try await engine.prepare { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.wire === wire, case .preparing = self.phase else { return }
                    self.phase = .preparing(phase: progress.phase, fraction: progress.fraction)
                }
            }

            for passage in passages {
                guard !wire.isCancelled else { return }
                // Hold here while paused, or while synthesis is far enough ahead.
                try await wire.waitUntilReadyForMore(maxLeadSeconds: Self.maxLeadSeconds)
                try await engine.synthesizeStreaming(text: passage, voice: nil, language: nil) { [weak self] chunk in
                    guard wire.enqueue(chunk) else { return false }
                    Task { @MainActor [weak self] in
                        self?.drainPendingChunks(wire: wire)
                    }
                    return true
                }
            }

            // Synthesis is done. A reading shorter than the start lead has never started —
            // start it now — then wait for the tail to play out before putting things away.
            guard !wire.isCancelled else { return }
            wire.markSynthesisFinished()
            drainPendingChunks(wire: wire)
            startVoiceIfReady(wire: wire)
            try await wire.waitUntilPlayedOut()
            guard self.wire === wire else { return }
            stop()
        } catch is CancellationError {
            // stop() already cleaned up.
        } catch {
            guard !wire.isCancelled else { return }
            ToastCenter.shared.show(.speakFailed((error as? LocalizedError)?.errorDescription
                                                 ?? error.localizedDescription))
            stop()
        }
    }

    /// Move every pending chunk, in order, onto the player node. Runs only on the main actor;
    /// the wire's locked FIFO preserves synthesis order even if the hop tasks arrive shuffled.
    private func drainPendingChunks(wire: SpeakWire) {
        guard self.wire === wire else { return }
        while let chunk = wire.dequeue() {
            schedule(chunk: chunk, wire: wire)
        }
        startVoiceIfReady(wire: wire)
    }

    private func schedule(chunk: SynthesizedSpeechChunk, wire: SpeakWire) {
        guard !chunk.samples.isEmpty else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(chunk.sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(chunk.samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        if let channel = buffer.floatChannelData?[0] {
            chunk.samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: chunk.samples.count)
            }
        }

        if playerNode == nil {
            guard startAudioGraph(format: format) else {
                ToastCenter.shared.show(.speakFailed("The audio engine couldn't start."))
                stop()
                return
            }
        }
        wire.recordScheduled(samples: chunk.samples.count, sampleRate: chunk.sampleRate)
        playerNode?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            wire.recordPlayed(samples: chunk.samples.count)
        }
    }

    /// Start the voice once enough lead is buffered (or synthesis already finished, for a
    /// reading shorter than the lead).
    private func startVoiceIfReady(wire: SpeakWire) {
        guard case .preparing = phase, let playerNode,
              wire.scheduledSeconds >= Self.startLeadSeconds || wire.synthesisFinished else { return }
        do {
            try playerNode.playAudio()
        } catch {
            ToastCenter.shared.show(.speakFailed(error.localizedDescription))
            stop()
            return
        }
        phase = .speaking
    }

    /// Build and start the audio graph for the voice's format. Returns whether it started.
    private func startAudioGraph(format: AVAudioFormat) -> Bool {
        activatePlaybackSession()
        let audioEngine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        audioEngine.attach(node)
        do {
            try audioEngine.connectNode(node, to: audioEngine.mainMixerNode, format: format)
            try audioEngine.start()
        } catch {
            return false
        }
        self.audioEngine = audioEngine
        self.playerNode = node
        return true
    }

    private func teardownPlayback() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Same session discipline as `PlaybackController`: a spoken transcript should be heard
    /// regardless of the ringer switch, and this never stomps recording's own
    /// `.playAndRecord` session (recording reconfigures on its next start).
    private func activatePlaybackSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }
}

/// One reading's state shared across threads — the synthesis callback (a background thread),
/// the player node's completion callbacks, and the main actor.
private final class SpeakWire: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var paused = false
        var pending: [SynthesizedSpeechChunk] = []
        var scheduledSamples = 0
        var playedSamples = 0
        var sampleRate = 0
        var synthesisFinished = false
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }
    func cancel() { state.withLock { $0.cancelled = true } }
    func setPaused(_ paused: Bool) { state.withLock { $0.paused = paused } }
    func markSynthesisFinished() { state.withLock { $0.synthesisFinished = true } }
    var synthesisFinished: Bool { state.withLock { $0.synthesisFinished } }

    /// Producer side: queue a chunk for the main actor. Returns whether the reading still
    /// wants audio — `false` cancels the synthesis through the seam's `onChunk` contract.
    func enqueue(_ chunk: SynthesizedSpeechChunk) -> Bool {
        state.withLock {
            guard !$0.cancelled else { return false }
            $0.pending.append(chunk)
            return true
        }
    }

    /// Main-actor side: next chunk in synthesis order, nil when drained.
    func dequeue() -> SynthesizedSpeechChunk? {
        state.withLock { $0.pending.isEmpty ? nil : $0.pending.removeFirst() }
    }

    func recordScheduled(samples: Int, sampleRate: Int) {
        state.withLock {
            $0.scheduledSamples += samples
            $0.sampleRate = sampleRate
        }
    }

    func recordPlayed(samples: Int) {
        state.withLock { $0.playedSamples += samples }
    }

    /// Seconds of audio scheduled so far (what the start gate compares).
    var scheduledSeconds: TimeInterval {
        state.withLock { $0.sampleRate > 0 ? Double($0.scheduledSamples) / Double($0.sampleRate) : 0 }
    }

    /// Hold the passage loop while playback is paused, or while synthesis is more than
    /// `maxLeadSeconds` ahead of the playhead.
    func waitUntilReadyForMore(maxLeadSeconds: TimeInterval) async throws {
        while true {
            try Task.checkCancellation()
            let wait = state.withLock { current -> Bool in
                guard !current.cancelled else { return false }
                if current.paused { return true }
                guard current.sampleRate > 0 else { return false }
                let lead = Double(current.scheduledSamples - current.playedSamples) / Double(current.sampleRate)
                return lead > maxLeadSeconds
            }
            guard wait else { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Hold until every scheduled sample has played back (or the reading was cancelled). A
    /// pause mid-tail simply keeps holding — resuming lets the tail finish.
    func waitUntilPlayedOut() async throws {
        while true {
            try Task.checkCancellation()
            let done = state.withLock { $0.cancelled || ($0.playedSamples >= $0.scheduledSamples && !$0.paused) }
            if done { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
