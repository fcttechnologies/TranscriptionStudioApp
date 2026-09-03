import FCTAccountProfile
import FCTBlobSync
import FCTServerSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// No synced model's wire row may name a server-managed column: the table template owns
/// `id, account_id, version, updated_seq, updated_at, deleted, deleted_at`, and a payload naming
/// one is `rejected` by the server. Pinned here so a future column rename fails this test instead
/// of a push in the field.
///
/// An app-side edit stamp renames instead (`edited_at` is the fleet pattern). **This app's own
/// models have none**: `TranscriptSession.createdAt` is a creation stamp, which is not reserved,
/// and nothing here records a last-edited time — the absence is pinned below rather than left to
/// be inferred from the loop passing. The shared account fragment does carry one, already renamed.
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
            (AccountOnboardingRecord.syncTableName,
             AccountOnboardingRecord(completedIn: TranscriptionSyncSchema.postgresSchema).syncRow()),
            (AccountProfileField.syncTableName,
             AccountProfileField(kind: .givenName, value: "Fernando").syncRow()),
            (AccountEngineDonation.syncTableName,
             AccountEngineDonation(donating: true).syncRow()),
        ]
        #expect(rows.count == TranscriptionSyncSchema.schema.tables.count, "every synced table is pinned here")
        for (table, row) in rows {
            let collisions = Set(row.keys).intersection(Self.reserved)
            #expect(collisions.isEmpty, "\(table) serializes reserved column(s): \(collisions.sorted())")
        }
    }

    /// The wire's column inventory, pinned against the migration.
    ///
    /// `sync_push` **rejects a payload naming a column the table does not have**, so a rename on
    /// this side that the SQL in `FCTPlatform` never hears about is not a mismatch that degrades:
    /// it is every push of that table failing in the field, with nothing on this side to catch it
    /// (the migration lives in another repo and no build can see it). This is that tripwire — the
    /// one place a reviewer can read the Swift wire and the SQL side by side.
    @Test @MainActor
    func theWireCarriesExactlyTheColumnsTheMigrationDeclares() {
        let expected: [String: Set<String>] = [
            TranscriptSession.syncTableName: [
                "title", "kind", "status", "created_at", "source_url", "audio", "duration",
                "full_text", "error_message", "is_private", "location_name", "latitude",
                "longitude", "claimed_at", "claimed_by", "highlights_status",
                "dismissed_suggestion_ids",
            ],
            StoredSegment.syncTableName: [
                "start_time", "end_time", "text", "track", "speaker_slot", "speaker_confidence",
                "avg_logprob", "no_speech_prob", "compression_ratio", "words", "session_id",
            ],
            TranscriptDecision.syncTableName: ["text", "session_id"],
            TranscriptActionItem.syncTableName: [
                "task", "owner", "due_date_text", "due_date", "done", "session_id",
            ],
            TranscriptEvent.syncTableName: ["title", "date_text", "date", "attendees", "session_id"],
            TranscriptPerson.syncTableName: ["name", "session_id"],
            TranscriptPlace.syncTableName: ["name", "session_id"],
            SpeakerAssignment.syncTableName: [
                "speaker_slot", "contact_identifier", "display_name", "session_id",
            ],
            MacPresence.syncTableName: ["device_id", "device_name", "last_seen"],
            // The shared account fragment, declared by this app and migrated by the platform.
            AccountOnboardingRecord.syncTableName: ["completed_at", "flow_version", "completed_in"],
            AccountProfileField.syncTableName: ["field", "value", "edited_at"],
            AccountEngineDonation.syncTableName: ["donating", "decided_at"],
        ]

        let session = TranscriptSession(title: "t", kind: .roomRecording)
        let rows: [String: [String: JSONValue]] = [
            TranscriptSession.syncTableName: session.syncRow(),
            StoredSegment.syncTableName: StoredSegment(start: 0, end: 1, text: "x").syncRow(),
            TranscriptDecision.syncTableName: TranscriptDecision(text: "x").syncRow(),
            TranscriptActionItem.syncTableName: TranscriptActionItem(task: "x").syncRow(),
            TranscriptEvent.syncTableName: TranscriptEvent(title: "x").syncRow(),
            TranscriptPerson.syncTableName: TranscriptPerson(name: "x").syncRow(),
            TranscriptPlace.syncTableName: TranscriptPlace(name: "x").syncRow(),
            SpeakerAssignment.syncTableName: SpeakerAssignment(
                speakerSlot: 0, contactIdentifier: "x", displayName: "x").syncRow(),
            MacPresence.syncTableName: MacPresence(deviceIDString: "x", deviceName: "x").syncRow(),
            AccountOnboardingRecord.syncTableName:
                AccountOnboardingRecord(completedIn: "x").syncRow(),
            AccountProfileField.syncTableName:
                AccountProfileField(kind: .givenName, value: "x").syncRow(),
            AccountEngineDonation.syncTableName: AccountEngineDonation(donating: false).syncRow(),
        ]

        #expect(Set(expected.keys) == Set(TranscriptionSyncSchema.schema.tables.map(\.name)))
        for (table, columns) in expected {
            #expect(Set(rows[table]?.keys ?? [:].keys) == columns, "\(table)'s wire columns drifted")
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
