import Foundation
import Observation
import SwiftData

/// Pure decision: does a store change that touched these entity names warrant re-fetching the
/// sessions feed? The feed lists `TranscriptSession`s whose displayed metadata (duration, speaker
/// count) derives from their `StoredSegment`s, so a change to either is relevant. Unrelated
/// writes — notably the `MacPresence` heartbeat that upserts every 60s — are not, and must not
/// churn the feed.
///
/// Fail-open by design: when the change set is *empty* (we couldn't identify what changed) we
/// refresh anyway, so a future notification-shape change degrades to "refetch a little more
/// often", never to "miss a local update". The skip only fires when a change is *positively*
/// identified as touching none of the feed's entities.
enum FeedRefreshDecision {
    /// The entity names whose changes affect the feed. Derived from the model types so a class
    /// rename tracks automatically (SwiftData's default entity name is the model's simple name).
    static let feedEntityNames: Set<String> = [
        String(describing: TranscriptSession.self),
        String(describing: StoredSegment.self),
    ]

    static func needsRefresh(changedEntityNames: Set<String>) -> Bool {
        guard !changedEntityNames.isEmpty else { return true }
        return !changedEntityNames.isDisjoint(with: feedEntityNames)
    }
}

/// Bridges the two store-change sources the sessions feed must react to into a single, observable
/// `changeToken` the feed re-fetches on.
///
/// A SwiftData `@Query` re-evaluates for *local* writes (SwiftData observes the store across the
/// app's several model contexts — recording, intents, the view context), but it does **not**
/// reliably re-evaluate when `NSPersistentCloudKitContainer` merges a *remote* import on its
/// background context. That merge lands in the store yet the feed stays stale until relaunch —
/// the bug this type fixes. So the feed drives itself from an explicit fetch instead, refreshed by:
///
/// - **Remote imports** — `HistoryObserver` (iOS 27) listens for `ModelContainer.remoteChange` and
///   bumps its `eventCounter`, filtered to `TranscriptSession` so a synced `MacPresence` heartbeat
///   from the other device doesn't churn the feed.
/// - **Local saves** — `ModelContext.didSave` (from any of the app's contexts), filtered through
///   ``FeedRefreshDecision`` so only session-affecting writes trigger a refetch.
@Observable
@MainActor
final class SessionStoreObserver {
    /// Increments on every relevant local save. Combined with the remote observer's counter in
    /// ``changeToken``.
    private(set) var saveGeneration = 0

    /// A single value the feed observes; it changes on any relevant remote import or local save.
    var changeToken: Int { saveGeneration &+ (historyObserver?.eventCounter ?? 0) }

    @ObservationIgnored private var historyObserver: HistoryObserver?
    @ObservationIgnored private var didSaveToken: (any NSObjectProtocol)?

    init(container: ModelContainer) {
        // Remote CloudKit imports of session rows. `try?`: a store without history providing
        // (e.g. an in-memory test store) simply leaves the remote path inactive — local still works.
        historyObserver = try? HistoryObserver(observedModels: [TranscriptSession.self],
                                               modelContainer: container)

        didSaveToken = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] note in
            let names = SessionStoreObserver.changedEntityNames(from: note)
            MainActor.assumeIsolated {
                guard let self, FeedRefreshDecision.needsRefresh(changedEntityNames: names) else { return }
                self.saveGeneration &+= 1
            }
        }
    }

    isolated deinit {
        if let didSaveToken { NotificationCenter.default.removeObserver(didSaveToken) }
    }

    /// The entity names touched by a `ModelContext.didSave` notification. Reads the inserted,
    /// updated, and deleted identifier sets; tolerant of whether `userInfo` is keyed by the
    /// `NotificationKey` case or its raw value.
    nonisolated static func changedEntityNames(from note: Notification) -> Set<String> {
        guard let userInfo = note.userInfo else { return [] }
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers,
        ]
        var names: Set<String> = []
        for key in keys {
            let value = userInfo[key] ?? userInfo[key.rawValue]
            if let ids = value as? Set<PersistentIdentifier> {
                names.formUnion(ids.map(\.entityName))
            } else if let ids = value as? [PersistentIdentifier] {
                names.formUnion(ids.map(\.entityName))
            }
        }
        return names
    }
}
