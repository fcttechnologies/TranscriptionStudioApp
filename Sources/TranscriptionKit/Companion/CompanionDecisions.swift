import Foundation

/// The pure, distributed-safe decisions the iOS↔Mac companion feature turns on — the claim lock,
/// the submit routing, and the presence-freshness read. Kept free of SwiftData and SwiftUI so the
/// correctness that matters (no double-processing, iOS-queues-vs-Mac-processes, connected-vs-stale)
/// is directly unit-testable without a CloudKit container or a live device.

/// Whether the Mac companion should take on a URL-transcription session it found in the shared
/// CloudKit store — the lock that keeps two devices (or one device across a relaunch) from
/// transcribing the same queued link twice.
///
/// Only the Mac ever claims (it alone has the yt-dlp/ffmpeg downloader). A freshly queued
/// `.pendingRemote` job is claimed; an `.inProgress` job already carries a claim marker, so it's
/// left alone unless its claim has gone stale (the claiming Mac died mid-download), in which case
/// it may be reclaimed rather than wedged forever. A Mac's *own* local URL job is also
/// `.inProgress` but has no claim marker, so it's never mistaken for remote work. Everything
/// else — local file/recording jobs, completed or failed sessions — is skipped.
public enum RemoteJobClaim {
    public enum Decision: Equatable, Sendable {
        /// Unclaimed queued work — take it.
        case claim
        /// A stale in-flight claim (the prior claimant went away) — take it over.
        case reclaim
        /// Not ours to process, or already being handled by a live claimant.
        case skip
    }

    /// - Parameters:
    ///   - kind: the session's kind — only `.urlTranscription` is ever remote work.
    ///   - status: the session's current status.
    ///   - claimedAt: the existing claim timestamp (`nil` = unclaimed / a local job).
    ///   - now: the current time.
    ///   - staleAfter: how long an in-flight claim may sit before it's considered abandoned and
    ///     reclaimable — generous enough to cover a real download+transcription.
    public static func decide(kind: SessionKind,
                              status: SessionStatus,
                              claimedAt: Date?,
                              now: Date,
                              staleAfter: TimeInterval) -> Decision {
        guard kind == .urlTranscription else { return .skip }
        switch status {
        case .pendingRemote:
            return .claim
        case .inProgress:
            // No claim marker → a Mac's own local URL job mid-flight, not remote work.
            guard let claimedAt else { return .skip }
            return now.timeIntervalSince(claimedAt) > staleAfter ? .reclaim : .skip
        case .complete, .failed:
            return .skip
        }
    }
}

/// Where a submitted link goes: transcribed locally on a device that has the URL downloader
/// (the Mac), or queued as a `.pendingRemote` job for a Mac to pick up over CloudKit (iOS).
/// The routing never depends on Mac presence — a link always queues; presence is display only.
public enum LinkSubmissionRoute {
    public enum Route: Equatable, Sendable {
        /// This device transcribes the URL itself (Mac: has yt-dlp/ffmpeg).
        case local
        /// Queue a `.pendingRemote` job for a Mac to claim (iOS: no downloader).
        case remote
    }

    public static func decide(hasURLDownloader: Bool) -> Route {
        hasURLDownloader ? .local : .remote
    }
}

/// The presence read iOS shows: is a Mac currently available to process queued links?
public enum MacPresenceStatus: Equatable, Sendable {
    /// A Mac heartbeat landed within the freshness window — "Mac connected".
    case connected
    /// A Mac checked in before, but not recently — "waiting for your Mac".
    case stale
    /// No Mac has ever checked in on this account.
    case absent

    /// - Parameters:
    ///   - lastSeen: the most recent Mac heartbeat, or `nil` if none has synced.
    ///   - now: the current time.
    ///   - freshWithin: how recent a heartbeat must be to count as connected (a few missed
    ///     beats' worth, so one dropped sync doesn't flip the indicator).
    public static func evaluate(lastSeen: Date?, now: Date, freshWithin: TimeInterval) -> MacPresenceStatus {
        guard let lastSeen else { return .absent }
        return now.timeIntervalSince(lastSeen) <= freshWithin ? .connected : .stale
    }
}
