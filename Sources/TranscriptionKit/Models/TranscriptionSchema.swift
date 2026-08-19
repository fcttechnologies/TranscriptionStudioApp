import Foundation
import SwiftData

/// V1 — unpublished, edited in place. Freeze + version on first public ship.
///
/// Every `@Model` in the app MUST be listed here: this is the store's membership, and the sync
/// layer's contract suite counts it against `TranscriptionSyncSchema.schema` so a model added
/// without a wire decision fails a test rather than shipping unsynced.
public enum TranscriptionSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
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

public typealias TranscriptionSchemaCurrent = TranscriptionSchemaV1

public enum TranscriptionSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [TranscriptionSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
