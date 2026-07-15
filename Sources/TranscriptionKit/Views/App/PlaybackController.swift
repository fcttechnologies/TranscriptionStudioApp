import AVFoundation
import Foundation
import Observation

/// Plays an archived session's audio and exposes a live playhead, so the library can seek to
/// a tapped segment's start — the ear-vs-label check in one click. Backed by `AVAudioPlayer`
/// (cross-platform); a lightweight main-actor tick advances the observed playhead while playing.
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    /// Whether a session's archived audio is currently loaded, so a surface knows whether
    /// playback is available.
    public private(set) var hasLoadedAudio = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

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
        isPlaying = true
        currentTime = player.currentTime
        startTicking()
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
            isPlaying = true
            startTicking()
        }
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
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}
