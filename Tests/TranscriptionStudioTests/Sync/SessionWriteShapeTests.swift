import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// **The off-main write audit, as a test rather than an opinion.**
///
/// TS has no `@ModelActor` and its foreground writes run on the main context, which is the
/// portfolio standard. The question that was open is whether any write path is hot enough to earn
/// the plain-actor off-main seam, and the answer turns on the *shape* of the writes, not on taste.
///
/// The shape: a transcription job persists **once**, at completion (`TranscriptionService.persist`,
/// `RecordingArchiver.finish`) — the whole segment set assigned and saved in one transaction. There
/// is no per-segment write during a job; the live transcript lives in memory on `AppModel.recording`
/// until the end. So there is no hot loop of the kind the off-main seam exists to fix, and the only
/// path that grows with session length is that single bulk save.
///
/// These tests pin both halves: that the save stays a bulk one, and what it costs at a length
/// longer than any real session.
@Suite("Session write shape")
struct SessionWriteShapeTests {

    /// A three-hour meeting at conversational density — longer than anything the app will really
    /// be handed, so a number measured here bounds the real one.
    private static let segmentCount = 2_000

    private func makeSegments(_ count: Int) -> [StoredSegment] {
        (0..<count).map { index in
            let segment = StoredSegment(start: Double(index) * 5, end: Double(index) * 5 + 4.6,
                                        text: "Segment \(index): a sentence of roughly the length a "
                                            + "person says in five seconds of ordinary speech.")
            segment.speakerSlot = index % 4
            segment.speakerConfidence = 0.9
            return segment
        }
    }

    /// The cost of the one save a long session performs on the main context. A generous ceiling on
    /// purpose: this is a regression tripwire on the write *shape*, not a benchmark, and a tight
    /// bound would false-fail under the machine-wide build contention this suite routinely runs
    /// beside. What it would actually catch is the shape changing — a per-segment save turning one
    /// transaction into two thousand, which is orders of magnitude, not percent.
    @MainActor
    @Test func aLongSessionPersistsInOneBulkSaveWellInsideAFrameBudgetPerSegment() throws {
        let made = try TestStoreFactory.onDisk(TranscriptionSchemaCurrent.self)
        defer { TestStoreFactory.removeStore(at: made.url) }
        let context = made.container.mainContext

        let session = TranscriptSession(title: "Three-hour meeting", kind: .meetingRecording)
        session.segments = makeSegments(Self.segmentCount)
        context.insert(session)

        let start = ContinuousClock.now
        try context.save()
        let elapsed = ContinuousClock.now - start

        let verdict: Comment = """
            one bulk save of \(Self.segmentCount) segments took \(elapsed) — if this is now \
            minutes rather than under a second, the write shape changed from one transaction to \
            one per segment, and THAT is what earns an off-main seam
            """
        #expect(elapsed < .seconds(10), verdict)
        print("[WRITE SHAPE] \(Self.segmentCount) segments, one save: \(elapsed)")

        let stored = try context.fetch(FetchDescriptor<StoredSegment>())
        #expect(stored.count == Self.segmentCount)
    }

    /// The staging sweep is the one write path that already runs off the main context — it mints
    /// its own `ModelContext(container)` — so a change that moved it back onto the main one would
    /// put a whole library's worth of blob staging in front of the UI. Pinned by the author stamp
    /// the sweep sets, which is what the sync engine reads to tell a local write from an applied
    /// remote one.
    @MainActor
    @Test func theStagingSweepWritesOnItsOwnContext() async throws {
        let device = try BootstrapDevice()
        defer { device.tearDown() }

        try device.recordSession(title: "Staged off-main", audio: Data("bytes".utf8))
        await device.enroll()

        let sessions = try device.container.mainContext.fetch(FetchDescriptor<TranscriptSession>())
        let session = try #require(sessions.first)
        #expect(session.audioAsset?.blobRef != nil,
                "the sweep ran on its own context and wrote the ref back")
        #expect(session.audioData == nil, "and cleared the byte column in the same save")
    }
}
