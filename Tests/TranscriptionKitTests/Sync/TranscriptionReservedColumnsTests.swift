import FCTBlobSync
import FCTServerSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionKit

/// No synced model's wire row may name a server-managed column: the table template owns
/// `id, account_id, version, updated_seq, updated_at, deleted, deleted_at`, and a payload naming
/// one is `rejected` by the server. Pinned here so a future column rename fails this test instead
/// of a push in the field.
///
/// An app-side edit stamp renames instead (`edited_at` is the fleet pattern). **This app has
/// none**: `TranscriptSession.createdAt` is a creation stamp, which is not reserved, and nothing
/// here records a last-edited time — the absence is pinned below rather than left to be inferred
/// from the loop passing.
@Suite("Reserved wire columns")
struct TranscriptionReservedColumnsTests {
    static let reserved: Set<String> = [
        "id", "account_id", "version", "updated_seq", "updated_at", "deleted", "deleted_at",
    ]

    @Test @MainActor
    func noSyncedRowNamesAServerManagedColumn() throws {
        // Fully-populated models, so every wire key each serializer can ever emit is present.
        let session = TranscriptSession(title: "Quarterly review", kind: .meetingRecording)
        session.statusRaw = SessionStatus.complete.rawValue
        session.sourceURLString = "https://example.com/a"
        session.audioAsset = .authored(BlobRef(
            id: UUID(), contentType: "audio/mp4", byteCount: 2, sha256: "ab", preview: nil
        ))
        session.duration = 61
        session.fullText = "text"
        session.errorMessage = "none"
        session.isPrivate = true
        session.locationName = "the office"
        session.coordinate = GeoCoordinate(latitude: 30.2, longitude: -97.7)
        session.claimedAt = .now
        session.claimedBy = "device"
        session.highlightsStatusRaw = HighlightsStatus.ready.rawValue
        session.dismissedSuggestionIDs = ["event:1"]

        let segment = StoredSegment(start: 0, end: 1, text: "hello")
        segment.words = [AsrWord(word: "hello", start: 0, end: 1, probability: 0.9)]
        segment.session = session

        let decision = TranscriptDecision(text: "ship it")
        decision.session = session
        let actionItem = TranscriptActionItem(task: "file it", owner: "me", dueDateText: "Friday", dueDate: .now)
        actionItem.done = true
        actionItem.session = session
        let event = TranscriptEvent(title: "standup", dateText: "tomorrow", date: .now, attendees: ["Sergio"])
        event.session = session
        let person = TranscriptPerson(name: "Sergio")
        person.session = session
        let place = TranscriptPlace(name: "the office")
        place.session = session
        let assignment = SpeakerAssignment(speakerSlot: 1, contactIdentifier: "ABC", displayName: "Sergio")
        assignment.session = session
        let presence = MacPresence(deviceIDString: "mac-1", deviceName: "Fernando's Mac")

        let rows: [(String, [String: JSONValue])] = [
            (TranscriptSession.syncTableName, session.syncRow()),
            (StoredSegment.syncTableName, segment.syncRow()),
            (TranscriptDecision.syncTableName, decision.syncRow()),
            (TranscriptActionItem.syncTableName, actionItem.syncRow()),
            (TranscriptEvent.syncTableName, event.syncRow()),
            (TranscriptPerson.syncTableName, person.syncRow()),
            (TranscriptPlace.syncTableName, place.syncRow()),
            (SpeakerAssignment.syncTableName, assignment.syncRow()),
            (MacPresence.syncTableName, presence.syncRow()),
        ]
        #expect(rows.count == TranscriptionSyncSchema.schema.tables.count, "every synced table is pinned here")
        for (table, row) in rows {
            let collisions = Set(row.keys).intersection(Self.reserved)
            #expect(collisions.isEmpty, "\(table) serializes reserved column(s): \(collisions.sorted())")
        }
    }

    /// The absence, pinned: no model carries an app-side edit stamp, so none needed the
    /// `updated_at` → `edited_at` rename the fleet does. If one is ever added, it must be named
    /// `edited_at` and this expectation is what will say so.
    @Test @MainActor
    func noModelCarriesAnAppSideEditStamp() {
        let session = TranscriptSession(title: "t", kind: .roomRecording)
        #expect(session.syncRow()["created_at"] != nil, "the creation stamp does ride, and is not reserved")
        #expect(session.syncRow()["edited_at"] == nil)
    }

    /// The derived columns that must never ride: `daySectionKey` is computed from `createdAt`
    /// (rule 4), and `audioData` is the pre-staging byte column the blob layer replaces (rule 7).
    /// Both would otherwise look like ordinary stored properties to a future serializer edit.
    @Test @MainActor
    func derivedAndPreStagingColumnsNeverRide() {
        let session = TranscriptSession(title: "t", kind: .roomRecording)
        session.audioData = Data([0x01, 0x02])
        let row = session.syncRow()
        #expect(row["day_section_key"] == nil)
        #expect(row["audio_data"] == nil)
        #expect(row["audio"]?.isNull == true, "an unstaged recording carries no asset")
    }
}
