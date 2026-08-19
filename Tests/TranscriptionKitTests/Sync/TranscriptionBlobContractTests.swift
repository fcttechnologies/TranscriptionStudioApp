import FCTBlobSync
import FCTBlobSyncTesting
import FCTServerSync
import FCTServerSyncTesting
import FCTSync
import Foundation
import SwiftData
import Testing
@testable import TranscriptionKit

/// The blob adapter: the record adapter plus the recording column
/// (`TranscriptSession.audioAsset`, the staged `AssetSource`).
@MainActor
struct TranscriptionBlobContractAdapter: BlobContractAdapter {
    private let records = TranscriptionSyncContractAdapter()

    var schema: SyncSchema { records.schema }
    var primaryTable: String { records.primaryTable }
    var markerColumn: String { records.markerColumn }
    var joins: [SyncJoinDescriptor] { records.joins }
    var appSlug: String { TranscriptionSyncSchema.postgresSchema }
    var blobColumn: String { "audio" }

    func makeStore() throws -> SyncContractStore { try records.makeStore() }

    func insert(marker: String, in container: ModelContainer) async throws -> UUID {
        try await records.insert(marker: marker, in: container)
    }

    func update(marker: String, on id: UUID, in container: ModelContainer) async throws {
        try await records.update(marker: marker, on: id, in: container)
    }

    func delete(_ id: UUID, in container: ModelContainer) async throws {
        try await records.delete(id, in: container)
    }

    func insert(asset: AssetSource, marker: String, in container: ModelContainer) async throws -> UUID {
        let id = try await records.insert(marker: marker, in: container)
        let context = container.mainContext
        guard let session = try context.fetch(TranscriptSession.descriptor(forSyncIDs: [id])).first else { return id }
        session.audioAsset = asset
        // The two-column invariant: the staged asset and the pre-staging bytes are never both
        // present, and the staging sweep is the only writer that moves a session across.
        session.audioData = nil
        try context.save()
        return id
    }

    func asset(of id: UUID, in container: ModelContainer) throws -> AssetSource? {
        let context = ModelContext(container)
        return try context.fetch(TranscriptSession.descriptor(forSyncIDs: [id])).first?.audioAsset
    }
}

/// The blob-layer contract, instantiated for this app's authored recordings: the app-slug ==
/// schema equality, the ordering rule and its full push cycle, the lazy digest-verified fetch,
/// and discard-on-delete.
@Suite("FCTBlobSync adopter contract — Transcription Studio instantiation")
struct TranscriptionBlobContractTests {
    @Test(arguments: BlobContractScenario.all)
    @MainActor
    func contract(_ scenario: BlobContractScenario) async throws {
        try await scenario.run(with: TranscriptionBlobContractAdapter())
    }
}
