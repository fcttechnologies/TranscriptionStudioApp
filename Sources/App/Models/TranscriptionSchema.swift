import Foundation
import SwiftData

/// V1 — unpublished, edited in place. Freeze + version on first public ship.
///
/// Every `@Model` in the app MUST be listed here: this is the store's membership, and the sync
/// layer's contract suite counts it against `TranscriptionSyncSchema.schema` so a model added
/// without a wire decision fails a test rather than shipping unsynced.
enum TranscriptionSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            TranscriptSession.self,
            StoredSegment.self,
            MacPresence.self,
            TranscriptDecision.self,
            TranscriptActionItem.self,
            TranscriptEvent.self,
            TranscriptPerson.self,
            TranscriptPlace.self,
            SpeakerAssignment.self,
        ]
    }
}

typealias TranscriptionSchemaCurrent = TranscriptionSchemaV1

enum TranscriptionSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TranscriptionSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
