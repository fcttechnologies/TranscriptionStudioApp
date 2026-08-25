import Foundation
import Testing
@testable import TranscriptionStudio

// The sessions feed re-fetches on store changes (local saves + changes the sync applier lands). This
// covers the pure "does this change matter to the feed?" decision that keeps a 60-second
// `MacPresence` heartbeat from churning the feed while never dropping a real session update.

@Suite("Feed refresh decision")
struct FeedRefreshDecisionTests {

    @Test func sessionChangeRefreshes() {
        #expect(FeedRefreshDecision.needsRefresh(changedEntityNames: ["TranscriptSession"]))
    }

    @Test func segmentChangeRefreshes() {
        // A session's shown metadata (duration, speaker count) derives from its segments.
        #expect(FeedRefreshDecision.needsRefresh(changedEntityNames: ["StoredSegment"]))
    }

    @Test func presenceOnlyChangeDoesNotRefresh() {
        #expect(!FeedRefreshDecision.needsRefresh(changedEntityNames: ["MacPresence"]))
    }

    @Test func mixedChangeRefreshes() {
        #expect(FeedRefreshDecision.needsRefresh(changedEntityNames: ["MacPresence", "TranscriptSession"]))
    }

    // Fail-open: an unidentifiable change refreshes rather than risk a missed update.
    @Test func unknownEmptyChangeRefreshes() {
        #expect(FeedRefreshDecision.needsRefresh(changedEntityNames: []))
    }

    // The feed's entity set is derived from the model types, so it matches their SwiftData names.
    @Test func feedEntityNamesMatchModels() {
        #expect(FeedRefreshDecision.feedEntityNames == ["TranscriptSession", "StoredSegment"])
    }
}
