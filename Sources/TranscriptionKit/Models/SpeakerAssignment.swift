import Foundation
import SwiftData

/// Binds a diarized speaker slot in a session to a real Contacts entry — the persistent half of
/// speaker→person mapping. A real queryable `@Model` (per-session, not a Codable blob) so a name
/// search or a future "everything Sergio said" is a plain fetch. The contact's `displayName` is
/// denormalized alongside the identifier so labels and the Spotlight index need no Contacts re-fetch
/// (and keep working even if read access is later revoked). CloudKit-ready: every attribute defaulted,
/// optional inverse, identity is the UUID `id`.
@Model
public final class SpeakerAssignment {
    #Index<SpeakerAssignment>([\.speakerSlot])

    public var id: UUID = UUID()
    /// The diarized speaker slot this binds: -1 = me, 0…3 = a diarized speaker (mirrors
    /// `StoredSegment.speakerSlot`).
    public var speakerSlot: Int = 0
    /// The bound contact's stable identifier (`CNContact.identifier`), for re-resolution.
    public var contactIdentifier: String = ""
    /// The bound contact's formatted name, denormalized for labels + name search.
    public var displayName: String = ""
    public var session: TranscriptSession?

    public init(speakerSlot: Int, contactIdentifier: String, displayName: String) {
        self.speakerSlot = speakerSlot
        self.contactIdentifier = contactIdentifier
        self.displayName = displayName
    }
}
