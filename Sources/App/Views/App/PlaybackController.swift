import AVFoundation
import FCTBlobSync
import FCTGlanceables
import Foundation
import Observation

/// Plays an archived session's audio and exposes a live playhead, so the library can seek to
/// a tapped segment's start — the ear-vs-label check in one click. Backed by `AVAudioPlayer`
/// (cross-platform); a lightweight main-actor tick advances the observed playhead while playing.
///
/// Loaded audio is also a real presence on the system's media surfaces: the controller keeps
/// `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` in sync (Lock Screen, Control Center,
/// AirPods transport — via FCTGlanceables' `NowPlayingCoordinator`) and, on iOS, drives the
/// playback Live Activity. Both follow the transport's discontinuities (play/pause/seek/rate);
/// the per-tick playhead never leaves the process.
@MainActor
@Observable
final class PlaybackController {
    /// What's loaded, for the mini-player: the session and the metadata it shows.
    struct NowPlaying: Equatable, Sendable {
        let sessionID: UUID
        let title: String
        let kind: SessionKind
    }

    /// The playback speeds the app offers, in the order the control cycles them.
    static let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Whether a session's archived audio is currently loaded, so a surface knows whether
    /// playback is available.
    private(set) var hasLoadedAudio = false
    /// The loaded session's identity/metadata (nil when nothing is loaded).
    private(set) var nowPlaying: NowPlaying?
    /// The current playback speed (persists across sessions until changed).
    private(set) var playbackRate: Float = 1

    /// True while a restored recording is downloading — the state a surface renders instead of a
    /// transport it cannot drive yet. Only ever true on a device that did not make the recording.
    private(set) var isFetchingRecording = false

    /// Fired just before playback starts (play or resume) — the hook `AppModel` uses to
    /// silence the read-aloud voice, so two audio surfaces never speak over each other.
    @ObservationIgnored var onTransportWillStart: (() -> Void)?

    /// Where a staged recording's bytes come from, wired by the app root to the blob layer.
    ///
    /// Both are nil before an account exists, which is exactly when only the pre-staging
    /// `audioData` column is reachable and nothing needs fetching.
    @ObservationIgnored var cachedRecordingBytes: ((AssetSource) -> Data?)?
    @ObservationIgnored var recordingBytes: ((AssetSource) async throws -> Data?)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let systemPlayer = NowPlayingCoordinator()
    #if os(iOS)
    @ObservationIgnored private let liveActivity = PlaybackLiveActivityDriver()
    #endif

    init() {}

    /// Load a session's recording for the detail sheet + mini-player. A no-op when the same
    /// session is already loaded, so reopening the sheet from the mini-player never interrupts
    /// playback. Returns whether audio is available.
    ///
    /// Async because a restored device pays for the bytes on the first play and not before: the
    /// recording is fetch-on-demand (the arithmetic is on `TranscriptSession.audioAsset`), so
    /// every other surface — the feed, the transcript, the duration, the date — renders from
    /// synced records while the audio is still `.notFetched`.
    @discardableResult
    func prepare(session: TranscriptSession) async -> Bool {
        if nowPlaying?.sessionID == session.id, hasLoadedAudio { return true }
        let loaded = await loadRecording(of: session)
        nowPlaying = loaded
            ? NowPlaying(sessionID: session.id, title: session.title, kind: session.kind)
            : nil
        if loaded { attachSystemPlayer() }
        return loaded
    }

    /// Drop the loaded audio entirely (a recording is starting, or an idle detail sheet
    /// closed without ever playing). The mini-player disappears with it, and the app's
    /// system-player presence (now-playing info, remote commands, Live Activity) is put away.
    func unload() {
        #if os(iOS)
        if let nowPlaying {
            let title = nowPlaying.title
            let duration = duration
            Task { [liveActivity] in await liveActivity.end(title: title, duration: duration) }
        }
        #endif
        stop()
        player = nil
        hasLoadedAudio = false
        duration = 0
        nowPlaying = nil
        systemPlayer.deactivate()
    }

    /// Release the loaded audio only if it was never engaged — keeps the mini-player alive
    /// after the detail sheet closes mid-play (or paused mid-way), drops it otherwise.
    func releaseIfIdle() {
        guard !isPlaying, currentTime == 0 else { return }
        unload()
    }

    /// Resolve a session's recording bytes, cheapest source first: the pre-staging column (this
    /// device recorded it and enrollment has not moved it yet), then the permanent blob cache
    /// (this device recorded it, or has fetched it once), then one digest-verified download.
    private func loadRecording(of session: TranscriptSession) async -> Bool {
        if let bytes = session.audioData { return load(data: bytes) }
        guard let asset = session.audioAsset else { return load(data: nil) }
        if let cached = cachedRecordingBytes?(asset) { return load(data: cached) }
        guard let fetch = recordingBytes else { return load(data: nil) }
        isFetchingRecording = true
        defer { isFetchingRecording = false }
        guard let bytes = try? await fetch(asset) else { return load(data: nil) }
        return load(data: bytes)
    }

    /// Load a session's archived audio from its compressed `Data`. Returns whether it loaded.
    @discardableResult
    func load(data: Data?) -> Bool {
        stop()
        guard let data else {
            player = nil
            hasLoadedAudio = false
            duration = 0
            return false
        }
        do {
            let player = try AVAudioPlayer(data: data)
            player.enableRate = true
            player.prepareToPlay()
            self.player = player
            self.hasLoadedAudio = true
            self.duration = player.duration
            self.currentTime = 0
            return true
        } catch {
            player = nil
            hasLoadedAudio = false
            duration = 0
            return false
        }
    }

    /// Seek to a time and start playing — used by tap-to-play on a segment.
    func play(from time: TimeInterval) {
        guard let player else { return }
        onTransportWillStart?()
        activatePlaybackSession()
        player.currentTime = min(max(time, 0), max(player.duration - 0.01, 0))
        player.play()
        player.rate = playbackRate
        isPlaying = true
        currentTime = player.currentTime
        startTicking()
        transportChanged()
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            onTransportWillStart?()
            activatePlaybackSession()
            player.play()
            player.rate = playbackRate
            isPlaying = true
            startTicking()
        }
        transportChanged()
    }

    /// Move the playhead without changing the play/pause state — the scrubber's drag.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), max(player.duration - 0.01, 0))
        currentTime = player.currentTime
        transportChanged()
    }

    /// Jump the playhead by a signed interval (the ±15s transport buttons).
    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// Change the playback speed; applies immediately when playing, and to the next play when
    /// paused.
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if let player, player.isPlaying {
            player.rate = rate
        }
        transportChanged()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        isPlaying = false
        currentTime = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Saved-session playback should be heard regardless of the ringer switch, so on iOS this
    /// puts the session in `.playback` (which ignores the silent switch) before each play —
    /// distinct from recording's own `.playAndRecord` session, which it reconfigures again the
    /// next time recording starts, so this never stomps it.
    private func activatePlaybackSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.playbackEnded()
                    return
                }
            }
        }
    }

    /// Playback ran out on its own (never through pause): the listening session is over, so the
    /// Live Activity ends and the system player shows paused-at-start (`AVAudioPlayer` rewinds
    /// its playhead to 0 after finishing).
    private func playbackEnded() {
        isPlaying = false
        publishNowPlaying()
        #if os(iOS)
        if let nowPlaying {
            let title = nowPlaying.title
            let duration = duration
            Task { [liveActivity] in await liveActivity.end(title: title, duration: duration) }
        }
        #endif
    }

    // MARK: System player (now-playing info + remote commands + Live Activity)

    /// Register the loaded session with the system's transport controls. Play/pause/skip/scrub
    /// and speed all route back into the controller — the Lock Screen player is a real remote.
    private func attachSystemPlayer() {
        systemPlayer.activate(commands: NowPlayingCommands(
            play: { [weak self] in
                guard let self, !self.isPlaying else { return }
                self.togglePlayPause()
            },
            pause: { [weak self] in
                guard let self, self.isPlaying else { return }
                self.togglePlayPause()
            },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            skipForward: { [weak self] in self?.skip(by: $0) },
            skipBackward: { [weak self] in self?.skip(by: -$0) },
            skipInterval: 15,
            seek: { [weak self] in self?.seek(to: $0) },
            changeRate: { [weak self] in self?.setPlaybackRate($0) },
            supportedRates: Self.playbackRates))
        publishNowPlaying()
    }

    /// A transport discontinuity (play/pause/seek/rate) — republish the anchors the system
    /// surfaces extrapolate the moving playhead from.
    private func transportChanged() {
        publishNowPlaying()
        #if os(iOS)
        if let nowPlaying {
            liveActivity.sync(sessionID: nowPlaying.sessionID,
                              kind: nowPlaying.kind,
                              title: nowPlaying.title,
                              isPlaying: isPlaying,
                              position: currentTime,
                              duration: duration,
                              rate: Double(playbackRate))
        }
        #endif
    }

    private func publishNowPlaying() {
        guard let nowPlaying, hasLoadedAudio else { return }
        systemPlayer.publish(NowPlayingItem(
            title: nowPlaying.title,
            artist: SessionKindStyle.label(nowPlaying.kind),
            duration: duration,
            elapsed: currentTime,
            rate: isPlaying ? Double(playbackRate) : 0))
    }
}
