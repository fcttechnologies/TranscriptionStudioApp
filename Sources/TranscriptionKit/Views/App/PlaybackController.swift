import AVFoundation
import Foundation
import Observation
import FCTGlanceables

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
public final class PlaybackController {
    /// What's loaded, for the mini-player: the session and the metadata it shows.
    public struct NowPlaying: Equatable, Sendable {
        public let sessionID: UUID
        public let title: String
        public let kind: SessionKind
    }

    /// The playback speeds the app offers, in the order the control cycles them.
    public static let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// Whether a session's archived audio is currently loaded, so a surface knows whether
    /// playback is available.
    public private(set) var hasLoadedAudio = false
    /// The loaded session's identity/metadata (nil when nothing is loaded).
    public private(set) var nowPlaying: NowPlaying?
    /// The current playback speed (persists across sessions until changed).
    public private(set) var playbackRate: Float = 1

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let systemPlayer = NowPlayingCoordinator()
    #if os(iOS)
    @ObservationIgnored private let liveActivity = PlaybackLiveActivityDriver()
    #endif

    public init() {}

    /// Load a session's archived audio for the detail sheet + mini-player. A no-op when the
    /// same session is already loaded, so reopening the sheet from the mini-player never
    /// interrupts playback. Returns whether audio is available.
    @discardableResult
    public func prepare(session: TranscriptSession) -> Bool {
        if nowPlaying?.sessionID == session.id, hasLoadedAudio { return true }
        let loaded = load(data: session.audioData)
        nowPlaying = loaded
            ? NowPlaying(sessionID: session.id, title: session.title, kind: session.kind)
            : nil
        if loaded { attachSystemPlayer() }
        return loaded
    }

    /// Drop the loaded audio entirely (a recording is starting, or an idle detail sheet
    /// closed without ever playing). The mini-player disappears with it, and the app's
    /// system-player presence (now-playing info, remote commands, Live Activity) is put away.
    public func unload() {
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
    public func releaseIfIdle() {
        guard !isPlaying, currentTime == 0 else { return }
        unload()
    }

    /// Load a session's archived audio from its compressed `Data`. Returns whether it loaded.
    @discardableResult
    public func load(data: Data?) -> Bool {
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
    public func play(from time: TimeInterval) {
        guard let player else { return }
        activatePlaybackSession()
        player.currentTime = min(max(time, 0), max(player.duration - 0.01, 0))
        player.play()
        player.rate = playbackRate
        isPlaying = true
        currentTime = player.currentTime
        startTicking()
        transportChanged()
    }

    public func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            activatePlaybackSession()
            player.play()
            player.rate = playbackRate
            isPlaying = true
            startTicking()
        }
        transportChanged()
    }

    /// Move the playhead without changing the play/pause state — the scrubber's drag.
    public func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), max(player.duration - 0.01, 0))
        currentTime = player.currentTime
        transportChanged()
    }

    /// Jump the playhead by a signed interval (the ±15s transport buttons).
    public func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// Change the playback speed; applies immediately when playing, and to the next play when
    /// paused.
    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if let player, player.isPlaying {
            player.rate = rate
        }
        transportChanged()
    }

    public func stop() {
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
