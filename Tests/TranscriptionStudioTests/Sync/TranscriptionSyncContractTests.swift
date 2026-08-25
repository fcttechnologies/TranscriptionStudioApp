import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionStudio

/// Transcription Studio's adapter for the FCTServerSync adopter contract suite.
///
/// The marker scenarios drive `TranscriptSession` — the hub every other record hangs off — through
/// its `title`, and the declared joins drive **this app's own** `applyLinks`/`relink` through every
/// arrival order. The module's fixture joins prove the engine's pending-role machinery wherever it
/// ships and prove nothing about a conformance that names the wrong column or drops a role, which
/// is what these close.
@MainActor
struct TranscriptionSyncContractAdapter: SyncContractAdapter {
    var schema: SyncSchema { TranscriptionSyncSchema.schema }
    var primaryTable: String { TranscriptSession.syncTableName }
    var markerColumn: String { "title" }

    func makeStore() throws -> SyncContractStore {
        let made = try TestStoreFactory.onDisk(TranscriptionSchemaCurrent.self)
        return SyncContractStore(container: made.container, url: made.url)
    }

    func insert(marker: String, in container: ModelContainer) async throws -> UUID {
        let context = container.mainContext
        let session = TranscriptSession(title: marker, kind: .roomRecording)
        context.insert(session)
        try context.save()
        return session.id
    }

    func update(marker: String, on id: UUID, in container: ModelContainer) async throws {
        let context = container.mainContext
        guard let session = try context.fetch(TranscriptSession.descriptor(forSyncIDs: [id])).first else { return }
        session.title = marker
        try context.save()
    }

    func delete(_ id: UUID, in container: ModelContainer) async throws {
        let context = container.mainContext
        guard let session = try context.fetch(TranscriptSession.descriptor(forSyncIDs: [id])).first else { return }
        context.delete(session)
        try context.save()
    }

    /// Every child model, each naming the session hub under the default role on `session_id`.
    /// They are declared individually rather than generically because a wrong wire column is
    /// exactly the mistake a shared helper would hide.
    var joins: [SyncJoinDescriptor] {
        [
            join("stored segment", StoredSegment.self) { StoredSegment(start: 1, end: 2, text: "hello") },
            join("decision", TranscriptDecision.self) { TranscriptDecision(text: "ship it") },
            join("action item", TranscriptActionItem.self) { TranscriptActionItem(task: "file the SQL") },
            join("event", TranscriptEvent.self) { TranscriptEvent(title: "standup") },
            join("person", TranscriptPerson.self) { TranscriptPerson(name: "Sergio") },
            join("place", TranscriptPlace.self) { TranscriptPlace(name: "the office") },
            join("speaker assignment", SpeakerAssignment.self) {
                SpeakerAssignment(speakerSlot: 1, contactIdentifier: "ABC", displayName: "Sergio")
            },
        ]
    }

    private func join<Child: SyncedModel & TranscriptSessionChild>(
        _ name: String,
        _ type: Child.Type,
        make: @escaping @MainActor () -> Child
    ) -> SyncJoinDescriptor {
        SyncJoinDescriptor(
            name: name,
            childTable: Child.syncTableName,
            roles: [.init(SyncLink.defaultRole, parentTable: TranscriptSession.syncTableName, column: "session_id")]
        ) { container in
            let context = container.mainContext
            let session = TranscriptSession(title: "parent of a \(name)", kind: .roomRecording)
            context.insert(session)
            let child = make()
            context.insert(child)
            child.session = session
            try context.save()
            return SyncJoinDescriptor.Seed(child: child.syncID, parents: [SyncLink.defaultRole: session.id])
        }
    }
}

/// The whole instantiation: one adapter, one parameterized test — the same scenarios every other
/// adopter runs, through this app's own models.
@Suite("FCTServerSync adopter contract — Transcription Studio instantiation")
struct TranscriptionSyncContractTests {
    @Test(arguments: SyncContractScenario.all)
    @MainActor
    func contract(_ scenario: SyncContractScenario) async throws {
        try await scenario.run(with: TranscriptionSyncContractAdapter())
    }

    /// The store's membership and the wire's must not drift apart: a `@Model` added to the schema
    /// without a wire decision is a model that silently never syncs, and nothing else would say so.
    @Test @MainActor func everyStoredModelHasAWireTable() {
        #expect(TranscriptionSchemaCurrent.models.count == TranscriptionSyncSchema.schema.tables.count)
        for table in TranscriptionSyncSchema.schema.tables {
            #expect(
                table.name.hasPrefix(TranscriptionSyncSchema.postgresSchema + "."),
                "\(table.name) is not in the app's Postgres schema"
            )
        }
    }
}
