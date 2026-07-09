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
    /// The file currently loaded, so a surface knows whether its audio is available.
    public private(set) var loadedFileName: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

    /// Load a session's archived audio by file name. Returns whether the file was found.
    @discardableResult
    public func load(fileName: String?) -> Bool {
        stop()
        guard let fileName, let url = AudioFileIO.url(forFileName: fileName),
              FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            loadedFileName = nil
            duration = 0
            return false
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            self.loadedFileName = fileName
            self.duration = player.duration
            self.currentTime = 0
            return true
        } catch {
            player = nil
            loadedFileName = nil
            return false
        }
    }

    /// Seek to a time and start playing — used by tap-to-play on a segment.
    public func play(from time: TimeInterval) {
        guard let player else { return }
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
