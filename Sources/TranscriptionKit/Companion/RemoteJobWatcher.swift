import CoreData
import Foundation
import SwiftData

/// The Mac-side observer that turns a link queued on iOS into a real transcription. It watches the
/// shared CloudKit store three ways — an initial scan on launch, `NSPersistentStoreRemoteChange`
/// notifications (a CloudKit import landed new work), and a periodic poll (the safety net when a
/// push is missed) — then **claims** one `.pendingRemote` session at a time (stamping a claim
/// marker so no other device double-processes it) and hands it to `process`, which runs the
/// existing URL pipeline into that same session. Its result (complete + segments, or failed)
/// syncs back to the phone.
///
/// Only ever started on the Mac (the device with the URL downloader). Scans are serialized by
/// `isScanning`, so overlapping triggers never launch two jobs at once.
@MainActor
public final class RemoteJobWatcher {
    private let modelContext: ModelContext
    private let deviceID: String
    private let staleClaimInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let process: @MainActor (TranscriptSession) async -> Void

    private var pollTask: Task<Void, Never>?
    private var remoteChangeObserver: NSObjectProtocol?
    private var isScanning = false

    /// - Parameters:
    ///   - staleClaimInterval: how long a claim may sit before another Mac may reclaim it (a
    ///     died-mid-download claimant shouldn't wedge the job forever). Default 10 minutes —
    ///     comfortably longer than a real download + transcription.
    ///   - pollInterval: the safety-net poll cadence for when a remote-change push is missed.
    public init(modelContext: ModelContext,
                deviceID: String,
                staleClaimInterval: TimeInterval = 600,
                pollInterval: TimeInterval = 45,
                process: @escaping @MainActor (TranscriptSession) async -> Void) {
        self.modelContext = modelContext
        self.deviceID = deviceID
        self.staleClaimInterval = staleClaimInterval
        self.pollInterval = pollInterval
        self.process = process
    }

    public func start() {
        // A CloudKit import landing new/updated rows posts this — the immediate trigger.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        // Launch scan + periodic safety-net poll.
        let pollInterval = self.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scan()
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
        }
        remoteChangeObserver = nil
    }

    /// Claim and process every claimable link, one at a time, until none remain. Re-entrant calls
    /// (a poll firing mid-process, or a remote-change notification) are dropped by `isScanning`,
    /// so at most one job runs at once.
    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        while let session = claimNext() {
            await process(session)
        }
    }

    /// Fetch candidate URL sessions, apply ``RemoteJobClaim`` to each, and atomically claim the
    /// first claimable one — persisting the claim (status → `.inProgress`, marker + timestamp)
    /// before returning it, so the claim is visible to every other device via sync. Returns the
    /// claimed session, or `nil` when there's nothing to do.
    private func claimNext() -> TranscriptSession? {
        let urlKind = SessionKind.urlTranscription.rawValue
        let pending = SessionStatus.pendingRemote.rawValue
        let inProgress = SessionStatus.inProgress.rawValue
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate {
                $0.kindRaw == urlKind && ($0.statusRaw == pending || $0.statusRaw == inProgress)
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        guard let candidates = try? modelContext.fetch(descriptor) else { return nil }

        let now = Date()
        for session in candidates {
            let decision = RemoteJobClaim.decide(kind: session.kind, status: session.status,
                                                 claimedAt: session.claimedAt, now: now,
                                                 staleAfter: staleClaimInterval)
            switch decision {
            case .claim, .reclaim:
                session.status = .inProgress
                session.claimedAt = now
                session.claimedBy = deviceID
                try? modelContext.save()
                return session
            case .skip:
                continue
            }
        }
        return nil
    }
}
