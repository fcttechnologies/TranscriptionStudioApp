import Testing
import Foundation
import SwiftData
@testable import TranscriptionKit

/// `TranscriptSpotlightIndex` behavior that doesn't require touching the real on-device Core
/// Spotlight index: the stable named-index identity (see `EntityDonator`'s data-protection
/// rationale) and the test-mode skip every call site relies on to stay silent under `swift test`.
@MainActor
struct SpotlightIndexTests {
    @Test func indexNameIsStable() {
        // Pinned so a rename is a deliberate, reviewed change — not an accidental one that
        // orphans whatever this named index already holds on a user's device.
        #expect(TranscriptSpotlightIndex.indexName == "TranscriptionStudioSessions")
    }

    @Test func indexDeindexAndReindexAllAreNoOpsUnderTests() throws {
        // AppModelContainer.isRunningTests is true for this process, so every entry point
        // must return immediately without touching Core Spotlight.
        #expect(AppModelContainer.isRunningTests)

        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Standup", kind: .roomRecording)
        context.insert(session)
        try context.save()

        TranscriptSpotlightIndex.index(session)
        TranscriptSpotlightIndex.deindex(id: session.id)
        TranscriptSpotlightIndex.reindexAll(in: container)
    }

    @Test func reindexAfterRenameIsANoOpUnderTests() throws {
        // Mirrors the two rename call sites (SessionDetailView.commitRename,
        // RenameTranscriptIntent.perform()): both save a new title, then re-index the
        // session so Spotlight's copy stops showing the stale one. Under tests this must
        // stay silent, exactly like a fresh `index(_:)` call.
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Standup", kind: .roomRecording)
        context.insert(session)
        try context.save()

        session.title = "Renamed Standup"
        try context.save()
        TranscriptSpotlightIndex.index(session)
    }
}
