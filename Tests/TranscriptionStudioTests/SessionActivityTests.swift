import Testing
import Foundation
@testable import TranscriptionStudio

/// The advertised viewing activity's field mapping — the activity-level on-screen annotation
/// cue. Pure configuration over a constructed `NSUserActivity`; no system services involved.
struct SessionActivityTests {

    @Test func configuresViewingActivityFields() {
        let activity = NSUserActivity(activityType: SessionActivity.viewingType)
        let id = UUID()

        SessionActivity.configureViewing(activity, sessionID: id, title: "Budget meeting")

        #expect(activity.title == "Budget meeting")
        #expect(activity.targetContentIdentifier == id.uuidString)
        #expect(activity.appEntityIdentifier != nil)
        // A context cue, never a continuation point: Handoff must stay opted out, and no
        // second search index via activity eligibility (the named Spotlight index owns search).
        #expect(activity.isEligibleForHandoff == false)
        #expect(activity.isEligibleForSearch == false)
    }
}
