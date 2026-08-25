// The companion feature's pure decision logic — the claim lock that prevents double-processing a
// queued link, the submit routing (iOS queues vs Mac transcribes), and the presence-freshness
// read. Container-free and deterministic; the real cross-device sync path needs two devices and is
// documented as a manual check in Documentation/COMPANION.md.

import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

@Suite("RemoteJobClaim — the Mac's claim/lock decision")
struct RemoteJobClaimTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let staleAfter: TimeInterval = 600

    @Test func aQueuedLinkIsClaimed() {
        #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: .pendingRemote,
                                      claimedAt: nil, now: now, staleAfter: staleAfter) == .claim)
    }

    @Test func aFreshlyClaimedJobIsSkipped() {
        // Claimed 10s ago — a live claimant is on it; don't double-process.
        let claimedAt = now.addingTimeInterval(-10)
        #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: .inProgress,
                                      claimedAt: claimedAt, now: now, staleAfter: staleAfter) == .skip)
    }

    @Test func aStaleClaimIsReclaimed() {
        // Claimed 20 minutes ago with no completion — the claimant died; take it over.
        let claimedAt = now.addingTimeInterval(-1200)
        #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: .inProgress,
                                      claimedAt: claimedAt, now: now, staleAfter: staleAfter) == .reclaim)
    }

    @Test func aLocalUrlJobInProgressWithoutAClaimMarkerIsSkipped() {
        // The Mac's own local Insert Link job is .inProgress but never carries a claim marker —
        // it must not be mistaken for reclaimable remote work.
        #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: .inProgress,
                                      claimedAt: nil, now: now, staleAfter: staleAfter) == .skip)
    }

    @Test func nonUrlKindsAreNeverClaimed() {
        for kind in [SessionKind.fileTranscription, .roomRecording, .meetingRecording] {
            #expect(RemoteJobClaim.decide(kind: kind, status: .pendingRemote,
                                          claimedAt: nil, now: now, staleAfter: staleAfter) == .skip)
        }
    }

    @Test func finishedSessionsAreSkipped() {
        for status in [SessionStatus.complete, .failed] {
            #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: status,
                                          claimedAt: now, now: now, staleAfter: staleAfter) == .skip)
        }
    }

    @Test func theStaleBoundaryIsExclusive() {
        // Exactly at the boundary is still "fresh" (skip); just past it flips to reclaim.
        let atBoundary = now.addingTimeInterval(-staleAfter)
        #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: .inProgress,
                                      claimedAt: atBoundary, now: now, staleAfter: staleAfter) == .skip)
        let pastBoundary = now.addingTimeInterval(-staleAfter - 1)
        #expect(RemoteJobClaim.decide(kind: .urlTranscription, status: .inProgress,
                                      claimedAt: pastBoundary, now: now, staleAfter: staleAfter) == .reclaim)
    }
}

@Suite("LinkSubmissionRoute — iOS queues, Mac transcribes")
struct LinkSubmissionRouteTests {
    @Test func aDeviceWithTheDownloaderTranscribesLocally() {
        #expect(LinkSubmissionRoute.decide(hasURLDownloader: true) == .local)
    }

    @Test func aDeviceWithoutTheDownloaderQueuesRemote() {
        #expect(LinkSubmissionRoute.decide(hasURLDownloader: false) == .remote)
    }
}

@Suite("MacPresenceStatus — the iOS presence read")
struct MacPresenceStatusTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let freshWithin: TimeInterval = 180

    @Test func noHeartbeatEverIsAbsent() {
        #expect(MacPresenceStatus.evaluate(lastSeen: nil, now: now, freshWithin: freshWithin) == .absent)
    }

    @Test func aRecentHeartbeatIsConnected() {
        let lastSeen = now.addingTimeInterval(-30)
        #expect(MacPresenceStatus.evaluate(lastSeen: lastSeen, now: now, freshWithin: freshWithin) == .connected)
    }

    @Test func anOldHeartbeatIsStale() {
        let lastSeen = now.addingTimeInterval(-600)
        #expect(MacPresenceStatus.evaluate(lastSeen: lastSeen, now: now, freshWithin: freshWithin) == .stale)
    }

    @Test func theFreshnessBoundaryIsInclusive() {
        let atBoundary = now.addingTimeInterval(-freshWithin)
        #expect(MacPresenceStatus.evaluate(lastSeen: atBoundary, now: now, freshWithin: freshWithin) == .connected)
        let pastBoundary = now.addingTimeInterval(-freshWithin - 1)
        #expect(MacPresenceStatus.evaluate(lastSeen: pastBoundary, now: now, freshWithin: freshWithin) == .stale)
    }
}

@Suite("AppModel.submitLink — the pendingRemote transition")
@MainActor
struct SubmitLinkTransitionTests {
    /// A model with no URL downloader (the iOS shape) queues a link as a `.pendingRemote` URL
    /// session — the exact row the Mac watcher later claims. It never attempts local URL
    /// transcription (which can only fail on iOS).
    @Test func aDownloaderlessModelQueuesAPendingRemoteSession() throws {
        let context = ModelContextFactory.makeInMemory()
        let app = AppModel(modelContext: context)   // mock model: urlDownloader == nil
        #expect(app.urlDownloader == nil)

        app.submitLink(urlString: "https://youtube.com/watch?v=abc", title: "Link · youtube.com")

        let sessions = try context.fetch(FetchDescriptor<TranscriptSession>())
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.status == .pendingRemote)
        #expect(session.kind == .urlTranscription)
        #expect(session.sourceURLString == "https://youtube.com/watch?v=abc")
        #expect(session.claimedAt == nil)
        #expect(session.isAwaitingRemote)
        #expect(!session.isProcessingRemote)
    }
}
