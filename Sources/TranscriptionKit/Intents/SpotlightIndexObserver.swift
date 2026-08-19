import Foundation
import Observation
import OSLog
import SwiftData

/// Pure decision for the incremental Spotlight reindex — which history transactions and changes
/// the observer should act on. Kept view-free and side-effect-free so it's directly testable,
/// mirroring ``FeedRefreshDecision``.
///
/// The two filters it encodes:
/// - **Author** — skip transactions authored by *this* device's own writes (they were already
///   indexed inline by `TranscriptSpotlightIndex.index`/`deindex` at each mutation). Anything else
///   — notably the sync applier's author on a change pulled from the other device — is processed.
///   Fail-open: an absent/unknown author is processed rather than skipped, so a real cross-device
///   change is never missed (same philosophy as ``FeedRefreshDecision``).
/// - **Entity** — only `TranscriptSession` changes touch the Spotlight index; a synced
///   `MacPresence` heartbeat or a `StoredSegment` row is ignored.
enum SpotlightReindexDecision {
    /// The author stamped on this device's local writes. See `AppModelContainer.localAuthorName`.
    static let localAuthorName = AppModelContainer.localAuthorName

    /// The one entity whose changes affect the Spotlight index, derived from the model type so a
    /// class rename tracks automatically (SwiftData's default entity name is the model's name).
    static let observedEntityName = String(describing: TranscriptSession.self)

    /// Process this transaction's changes? Skips our own already-indexed local writes.
    static func shouldProcess(transactionAuthor author: String?) -> Bool {
        author != localAuthorName
    }

    /// Does a change to this entity affect the Spotlight index?
    static func affectsSpotlight(entityName: String) -> Bool {
        entityName == observedEntityName
    }
}

/// Keeps this device's named Spotlight index fresh with changes that arrive by sync —
/// the gap `TranscriptSpotlightIndex.reindexAll` (launch-only) leaves open while the app is
/// running. A session created, renamed, or deleted on the *other* device now lands in this
/// device's `"TranscriptionStudioSessions"` index the moment its sync merges, not at next launch.
///
/// Mechanism (SDK 27): a `HistoryObserver` filtered to `TranscriptSession` bumps its `eventCounter`
/// on every relevant `ModelContainer.remoteChange`. On each bump we fetch the new history
/// transactions, drop our own local-authored writes (already indexed inline — see
/// ``SpotlightReindexDecision``), and incrementally re-index the affected sessions:
/// insert/update → `index`, delete → `deindex` (recovering the session's UUID from the history
/// tombstone, which is why `TranscriptSession.id` is `.preserveValueOnDeletion`).
///
/// This is a **separate** observer from ``SessionStoreObserver`` (which refreshes the *feed*):
/// same `HistoryObserver` pattern, a different consumer.
@Observable
@MainActor
public final class SpotlightIndexObserver {
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var historyObserver: HistoryObserver?
    /// The newest history token we've already processed; the next fetch asks only for later ones.
    @ObservationIgnored private var lastToken: DefaultHistoryToken?

    public init(container: ModelContainer) {
        self.container = container
        // Indexing is a no-op under tests, and an in-memory test store has no history provider —
        // skip the whole observer there, matching `TranscriptSpotlightIndex`'s test posture.
        guard !AppModelContainer.isRunningTests else { return }
        // `try?`: a store without history providing simply leaves the observer inactive; launch's
        // `reindexAll` still covers everything, and local writes still index inline.
        historyObserver = try? HistoryObserver(observedModels: [TranscriptSession.self],
                                               modelContainer: container)
        guard historyObserver != nil else { return }
        captureBaselineToken()
        arm()
    }

    /// Baseline at the newest existing transaction so the first remote event only processes
    /// genuinely new changes — launch's `reindexAll` already covered everything up to now.
    private func captureBaselineToken() {
        let context = ModelContext(container)
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.sortBy = [SortDescriptor(\.token, order: .reverse)]
        descriptor.fetchLimit = 1
        lastToken = (try? context.fetchHistory(descriptor))?.first?.token
    }

    /// Re-arm on every `eventCounter` change. `withObservationTracking`'s `onChange` fires once,
    /// just before the next mutation, so we re-register inside it to keep observing for the
    /// observer's whole lifetime. Re-arm *before* processing so a remote change that lands while
    /// we're indexing still triggers the next pass (and `processChanges` fetches all history since
    /// our last token regardless, so nothing is dropped either way).
    private func arm() {
        guard let historyObserver else { return }
        withObservationTracking {
            _ = historyObserver.eventCounter
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.arm()
                self.processChanges()
            }
        }
    }

    /// Fetch the history added since `lastToken`, drop our own writes, and apply the incremental
    /// index/deindex for the sessions a synced change touched.
    private func processChanges() {
        let context = ModelContext(container)
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let token = lastToken {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        guard let transactions = try? context.fetchHistory(descriptor), !transactions.isEmpty else { return }

        var upsertIDs: Set<PersistentIdentifier> = []
        var deindexUUIDs: Set<UUID> = []

        for transaction in transactions {
            defer { lastToken = transaction.token }
            guard SpotlightReindexDecision.shouldProcess(transactionAuthor: transaction.author) else { continue }
            for change in transaction.changes {
                let identifier = change.changedPersistentIdentifier
                guard SpotlightReindexDecision.affectsSpotlight(entityName: identifier.entityName) else { continue }
                switch change {
                case .insert, .update:
                    upsertIDs.insert(identifier)
                case .delete(let deletion):
                    // The row is gone — recover its stable UUID from the preserved tombstone.
                    if let uuid = (deletion as? DefaultHistoryDelete<TranscriptSession>)?.tombstone[\.id] as? UUID {
                        deindexUUIDs.insert(uuid)
                    }
                @unknown default:
                    continue
                }
            }
        }

        apply(upsertIDs: upsertIDs, deindexUUIDs: deindexUUIDs, in: context)
    }

    private func apply(upsertIDs: Set<PersistentIdentifier>, deindexUUIDs: Set<UUID>, in context: ModelContext) {
        for identifier in upsertIDs {
            var descriptor = FetchDescriptor<TranscriptSession>(
                predicate: #Predicate { $0.persistentModelID == identifier })
            descriptor.fetchLimit = 1
            // A session upserted then deleted in the same batch fetches as nil here — its `index`
            // is correctly skipped, and its `deindex` still runs below.
            if let session = try? context.fetch(descriptor).first {
                TranscriptSpotlightIndex.index(session)
            }
        }
        for uuid in deindexUUIDs {
            TranscriptSpotlightIndex.deindex(id: uuid)
        }
        if !upsertIDs.isEmpty || !deindexUUIDs.isEmpty {
            Logger.persistence.info(
                "Spotlight incremental sync: \(upsertIDs.count, privacy: .public) reindexed, \(deindexUUIDs.count, privacy: .public) removed")
        }
    }
}
