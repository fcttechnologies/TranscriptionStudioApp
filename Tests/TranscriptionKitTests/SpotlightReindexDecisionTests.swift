import Foundation
import Testing
@testable import TranscriptionKit

// The incremental Spotlight observer reindexes sessions changed on the *other* device the moment
// their CloudKit sync merges. This covers the two pure filters that decide what it acts on:
// skip our own already-inline-indexed writes (author), and only care about session rows (entity).

@Suite("Spotlight reindex decision")
struct SpotlightReindexDecisionTests {

    // MARK: Author filter — skip our own writes, process everything else

    @Test func ourOwnLocalWritesAreSkipped() {
        // Local writes carry `localAuthorName` and were already indexed inline at the mutation.
        #expect(!SpotlightReindexDecision.shouldProcess(transactionAuthor: SpotlightReindexDecision.localAuthorName))
        #expect(!SpotlightReindexDecision.shouldProcess(transactionAuthor: AppModelContainer.localAuthorName))
    }

    @Test func syncedChangesFromAnotherAuthorAreProcessed() {
        // CloudKit stamps its own import author on a change synced from the other device.
        #expect(SpotlightReindexDecision.shouldProcess(transactionAuthor: "NSCloudKitMirroringDelegate.import"))
    }

    // Fail-open: an unidentifiable author is processed rather than risk missing a real update.
    @Test func unknownOrAbsentAuthorIsProcessed() {
        #expect(SpotlightReindexDecision.shouldProcess(transactionAuthor: nil))
        #expect(SpotlightReindexDecision.shouldProcess(transactionAuthor: ""))
        #expect(SpotlightReindexDecision.shouldProcess(transactionAuthor: "some.other.device"))
    }

    // MARK: Entity filter — only session rows touch the Spotlight index

    @Test func onlySessionEntityAffectsSpotlight() {
        #expect(SpotlightReindexDecision.affectsSpotlight(entityName: "TranscriptSession"))
        // A synced presence heartbeat or a segment row must not trigger a reindex.
        #expect(!SpotlightReindexDecision.affectsSpotlight(entityName: "MacPresence"))
        #expect(!SpotlightReindexDecision.affectsSpotlight(entityName: "StoredSegment"))
    }

    // The observed entity name is derived from the model type, so it tracks a class rename.
    @Test func observedEntityNameMatchesModel() {
        #expect(SpotlightReindexDecision.observedEntityName == String(describing: TranscriptSession.self))
        #expect(SpotlightReindexDecision.observedEntityName == "TranscriptSession")
    }
}
