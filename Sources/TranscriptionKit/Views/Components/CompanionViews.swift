import SwiftUI
import SwiftData
import FCTCloudKit

/// A subtle CloudKit sync-status indicator for the shell's toolbar. Reads the injected
/// ``CloudKitSyncMonitor`` (FCTFoundation) and shows a quiet glyph while syncing or on error;
/// idle shows nothing (sync is invisible when it's working). The companion UX leans on this —
/// a link queued on the phone only reaches the Mac once the store has synced, so the user
/// wants to see that it's happening.
struct SyncStatusIndicator: View {
    let monitor: CloudKitSyncMonitor?

    var body: some View {
        switch monitor?.status {
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Syncing")
        case .error:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
                .accessibilityLabel("Sync error")
        case .idle, .none:
            EmptyView()
        }
    }
}

/// The iOS-facing "is a Mac available?" badge. Reads the most recent ``MacPresence`` heartbeat
/// and renders connected / waiting through ``MacPresenceStatus``. Display only — it never gates
/// queuing a link.
struct MacPresenceBadge: View {
    @Query(sort: \MacPresence.lastSeen, order: .reverse) private var presences: [MacPresence]

    /// A Mac beats every 60s; treat three missed beats as gone so one dropped sync doesn't flip it.
    private let freshWithin: TimeInterval = 180

    var body: some View {
        let latest = presences.first
        let status = MacPresenceStatus.evaluate(lastSeen: latest?.lastSeen, now: Date(),
                                                freshWithin: freshWithin)
        Label {
            Text(text(for: status, name: latest?.deviceName))
        } icon: {
            Image(systemName: icon(for: status))
        }
        .font(.caption)
        .foregroundStyle(status == .connected ? Color.green : .secondary)
    }

    private func text(for status: MacPresenceStatus, name: String?) -> String {
        switch status {
        case .connected: return "\(name ?? "Your Mac") connected"
        case .stale: return "Waiting for your Mac"
        case .absent: return "No Mac connected yet"
        }
    }

    private func icon(for status: MacPresenceStatus) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .stale, .absent: return "hourglass"
        }
    }
}

/// The placeholder a `.pendingRemote` (or Mac-claimed, still-processing) session shows in its
/// detail sheet instead of an empty transcript — a clear "waiting for your Mac…" state that turns
/// into the real transcript once the Mac finishes and it syncs back.
struct RemoteWaitingView: View {
    /// True once a Mac has claimed the job and is actively transcribing it.
    let isProcessing: Bool

    var body: some View {
        ContentUnavailableView {
            Label(isProcessing ? "Transcribing on your Mac" : "Waiting for your Mac",
                  systemImage: isProcessing ? "waveform" : "hourglass")
        } description: {
            Text(isProcessing
                 ? "Your Mac is downloading and transcribing this link. It'll appear here when it's done."
                 : "This link is queued. Open Transcription Studio on your Mac to transcribe it — the result syncs back here.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// Whether a session is a companion remote job still awaiting its transcript — the shared test the
/// feed row and the detail sheet both use to decide between the normal UI and the waiting state.
extension TranscriptSession {
    /// Queued on iOS, not yet claimed by a Mac.
    var isAwaitingRemote: Bool { status == .pendingRemote }
    /// Claimed by a Mac and transcribing now (its result will sync back).
    var isProcessingRemote: Bool { status == .inProgress && claimedAt != nil }
    /// Either waiting state — show the companion placeholder rather than the transcript.
    var isRemotePlaceholder: Bool { isAwaitingRemote || isProcessingRemote }
}
