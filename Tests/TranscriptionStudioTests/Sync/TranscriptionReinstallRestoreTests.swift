import FCTBlobSync
import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// The delete-reinstall-sign-in shape, proven for this app's own data.
///
/// The shared contract suites prove the *mechanisms*; this proves Transcription Studio's
/// serialization survives the round trip whole. A first device seeds models exercising EVERY
/// synced field on every table and pushes; a second device on the same account — fresh store,
/// fresh state file, fresh cache, cursor 0 — syncs and must hold every record content-identical.
///
/// And it pins the one promise the audio decision rests on: **the transcript is fully present
/// before a single byte of audio moves.** The recording stays `.notFetched` until something
/// plays it, then caches permanently.
@Suite("Reinstall restore — Transcription Studio's own data")
struct TranscriptionReinstallRestoreTests {
    @MainActor
    @Test func reinstallRestoresEverySyncedFieldContentIdentical() async throws {
        let server = FakeSyncServer()
        let objects = FakeBlobObjectStore()
        let first = try BootstrapDevice(server: server, objects: objects)
        defer { first.tearDown() }

        // --- Seed, exercising every synced field on every table. ---

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = Data("the meeting itself, in AAC".utf8)
        let context = first.container.mainContext

        let session = TranscriptSession(title: "Quarterly review", kind: .meetingRecording, createdAt: createdAt)
        session.statusRaw = SessionStatus.complete.rawValue
        session.sourceURLString = "https://example.com/a.mp4"
        session.audioData = recording
        session.duration = 3_612.5
        session.fullText = "Sergio: we ship Friday."
        session.errorMessage = "a warning that was recorded"
        session.isPrivate = true
        session.locationName = "the office"
        session.coordinate = GeoCoordinate(latitude: 30.2672, longitude: -97.7431)
        session.claimedAt = Date(timeIntervalSince1970: 1_700_000_500)
        session.claimedBy = "fernandos-mac"
        session.highlightsStatusRaw = HighlightsStatus.ready.rawValue
        session.dismissedSuggestionIDs = ["event:1", "action:2"]
        context.insert(session)

        let segment = StoredSegment(start: 12.5, end: 17.25, text: "we ship Friday")
        segment.trackRaw = AudioTrack.microphone.rawValue
        segment.speakerSlot = 2
        segment.speakerConfidence = 0.87
        segment.avgLogprob = -0.21
        segment.noSpeechProb = 0.03
        segment.compressionRatio = 1.9
        segment.words = [AsrWord(word: "Friday", start: 16, end: 17.25, probability: 0.94)]
        segment.session = session
        context.insert(segment)

        let decision = TranscriptDecision(text: "Ship on Friday")
        decision.session = session
        context.insert(decision)

        let actionItem = TranscriptActionItem(
            task: "File the migration", owner: "Sergio", dueDateText: "next Tuesday",
            dueDate: Date(timeIntervalSince1970: 1_700_500_000))
        actionItem.done = true
        actionItem.session = session
        context.insert(actionItem)

        let event = TranscriptEvent(
            title: "Launch review", dateText: "Friday at 9",
            date: Date(timeIntervalSince1970: 1_700_400_000), attendees: ["Sergio", "Ana"])
        event.session = session
        context.insert(event)

        let person = TranscriptPerson(name: "Sergio")
        person.session = session
        context.insert(person)

        let place = TranscriptPlace(name: "the Austin office")
        place.session = session
        context.insert(place)

        let assignment = SpeakerAssignment(speakerSlot: 2, contactIdentifier: "CN-42", displayName: "Sergio R.")
        assignment.session = session
        context.insert(assignment)

        let presence = MacPresence(
            deviceIDString: "mac-1", deviceName: "Fernando's Mac",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_900))
        context.insert(presence)
        try context.save()

        let sessionID = session.id
        let segmentID = segment.id
        let ids = (decision: decision.id, actionItem: actionItem.id, event: event.id,
                   person: person.id, place: place.id, assignment: assignment.id,
                   presence: presence.id)

        // --- Enrol: stage the recording (rule 7), drain the upload, push every record. ---
        await first.enroll()
        #expect(first.sync.unsyncedWork == 0, "the seed must push clean, held nothing")
        let sourceRef = try #require(try first.session(sessionID)?.audioAsset?.blobRef)
        #expect(try first.session(sessionID)?.audioData == nil, "the pre-staging column is cleared")

        // --- The reinstall: fresh store, state file and cache; same account; cursor 0. ---
        let second = try BootstrapDevice(server: server, objects: objects, accountID: first.accountID)
        defer { second.tearDown() }
        await second.sync.handle(.resumed(second.accountID))

        let restored = ModelContext(second.container)

        // The session, field by field.
        let s = try #require(restored.fetch(TranscriptSession.descriptor(forSyncIDs: [sessionID])).first)
        #expect(s.title == "Quarterly review")
        #expect(s.kind == .meetingRecording)
        #expect(s.status == .complete)
        #expect(abs(s.createdAt.timeIntervalSince(createdAt)) < 0.001)
        #expect(s.daySectionKey == DaySectionKey.string(for: createdAt),
                "the derived day key is re-derived from the pulled createdAt, never carried")
        #expect(s.sourceURLString == "https://example.com/a.mp4")
        #expect(s.duration == 3_612.5)
        #expect(s.fullText == "Sergio: we ship Friday.")
        #expect(s.errorMessage == "a warning that was recorded")
        #expect(s.isPrivate == true)
        #expect(s.locationName == "the office")
        #expect(s.coordinate == GeoCoordinate(latitude: 30.2672, longitude: -97.7431))
        #expect(abs(try #require(s.claimedAt).timeIntervalSince1970 - 1_700_000_500) < 0.001)
        #expect(s.claimedBy == "fernandos-mac")
        #expect(s.highlightsStatus == .ready)
        #expect(s.dismissedSuggestionIDs == ["event:1", "action:2"])
        #expect(s.audioData == nil, "pre-staging bytes never travel")

        // The transcript: fully present, from record sync alone.
        let seg = try #require(restored.fetch(StoredSegment.descriptor(forSyncIDs: [segmentID])).first)
        #expect(seg.start == 12.5)
        #expect(seg.end == 17.25)
        #expect(seg.text == "we ship Friday")
        #expect(seg.trackRaw == AudioTrack.microphone.rawValue)
        #expect(seg.speakerSlot == 2)
        #expect(abs(seg.speakerConfidence - 0.87) < 0.0001)
        #expect(abs(seg.avgLogprob - -0.21) < 0.0001)
        #expect(abs(seg.noSpeechProb - 0.03) < 0.0001)
        #expect(abs(seg.compressionRatio - 1.9) < 0.0001)
        #expect(seg.words?.first?.word == "Friday")
        #expect(abs((seg.words?.first?.probability ?? 0) - 0.94) < 0.0001)
        #expect(seg.session?.id == sessionID, "the parent link must be re-attached")

        let d = try #require(restored.fetch(TranscriptDecision.descriptor(forSyncIDs: [ids.decision])).first)
        #expect(d.text == "Ship on Friday")
        #expect(d.session?.id == sessionID)

        let a = try #require(restored.fetch(TranscriptActionItem.descriptor(forSyncIDs: [ids.actionItem])).first)
        #expect(a.task == "File the migration")
        #expect(a.owner == "Sergio")
        #expect(a.dueDateText == "next Tuesday")
        #expect(abs(try #require(a.dueDate).timeIntervalSince1970 - 1_700_500_000) < 0.001)
        #expect(a.done == true)
        #expect(a.session?.id == sessionID)

        let e = try #require(restored.fetch(TranscriptEvent.descriptor(forSyncIDs: [ids.event])).first)
        #expect(e.title == "Launch review")
        #expect(e.dateText == "Friday at 9")
        #expect(abs(try #require(e.date).timeIntervalSince1970 - 1_700_400_000) < 0.001)
        #expect(e.attendees == ["Sergio", "Ana"])
        #expect(e.session?.id == sessionID)

        let p = try #require(restored.fetch(TranscriptPerson.descriptor(forSyncIDs: [ids.person])).first)
        #expect(p.name == "Sergio")
        #expect(p.session?.id == sessionID)

        let pl = try #require(restored.fetch(TranscriptPlace.descriptor(forSyncIDs: [ids.place])).first)
        #expect(pl.name == "the Austin office")
        #expect(pl.session?.id == sessionID)

        let sa = try #require(restored.fetch(SpeakerAssignment.descriptor(forSyncIDs: [ids.assignment])).first)
        #expect(sa.speakerSlot == 2)
        #expect(sa.contactIdentifier == "CN-42")
        #expect(sa.displayName == "Sergio R.")
        #expect(sa.session?.id == sessionID)

        let mp = try #require(restored.fetch(MacPresence.descriptor(forSyncIDs: [ids.presence])).first)
        #expect(mp.deviceIDString == "mac-1")
        #expect(mp.deviceName == "Fernando's Mac")
        #expect(abs(mp.lastSeen.timeIntervalSince1970 - 1_700_000_900) < 0.001)

        // --- The audio decision, proven end to end. ---
        let ref = try #require(s.audioAsset?.blobRef, "the asset column round-trips")
        #expect(ref.id == sourceRef.id)
        #expect(ref.sha256 == sourceRef.sha256)
        #expect(ref.byteCount == sourceRef.byteCount)
        #expect(ref.preview == nil, "this app ships no audio preview — the list renders from metadata")
        let blobs = try #require(second.sync.blobStore)
        #expect(blobs.fetchState(of: ref) == .notFetched,
                "record sync must not pull a single byte of audio")
        #expect(blobs.cachedData(for: ref) == nil)

        // …and then somebody presses play.
        let playback = PlaybackController()
        playback.cachedRecordingBytes = { second.sync.cachedRecordingData(for: $0) }
        playback.recordingBytes = { try await second.sync.recordingData(for: $0) }
        _ = await playback.prepare(session: s)
        #expect(blobs.cachedData(for: ref) == recording,
                "the first play fetches the recording once, digest-verified, and caches it forever")
        #expect(blobs.fetchState(of: ref) == .cached)

        // No extra rows may appear anywhere, and a restore is the applier's write: it pushes nothing.
        #expect(try restored.fetchCount(FetchDescriptor<TranscriptSession>()) == 1)
        #expect(try restored.fetchCount(FetchDescriptor<StoredSegment>()) == 1)
        #expect(try restored.fetchCount(FetchDescriptor<MacPresence>()) == 1)
        #expect(second.sync.unsyncedWork == 0, "a restore must push nothing back up")
    }
}
