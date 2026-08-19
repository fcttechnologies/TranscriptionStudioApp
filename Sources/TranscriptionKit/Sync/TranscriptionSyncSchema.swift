import FCTBlobSync
import FCTServerSync
import Foundation
import SwiftData

/// Transcription Studio's wire: which models sync, to which tables, under which version.
///
/// **All nine of the app's `@Model`s sync**, which is the honest answer for a library whose whole
/// point is that it follows you. The shape is the contract's best case: one hub
/// (`TranscriptSession`) and eight rootless-or-child records, every child naming exactly one
/// parent by uuid, and every child append-only in practice — a transcript's segments, decisions,
/// action items, events, people and places are written once by the extraction pass and then read.
/// LWW is vacuous on almost all of it.
///
/// **The transcript is records, not blobs, and that is the design's load-bearing half.** Segments,
/// decisions, action items, events, people, places and speaker bindings all cross as ordinary
/// rows, so a reinstalled device renders the library and every word of every transcript from
/// record sync alone, with zero storage egress — before a single byte of audio is fetched. Only
/// the recording itself is a blob (`TranscriptSession.audioAsset`, model contract rule 7), and it
/// is fetched on demand; the arithmetic that makes that non-negotiable is stated on that property.
///
/// `daySectionKey` is derived from `createdAt` and never rides the wire (rule 4); `audioData` is
/// the pre-staging byte column and never rides either.
public enum TranscriptionSyncSchema {
    /// The app's Postgres schema. `BlobStore(appSlug:)` **is** this string: blob keys are
    /// `<account>/<schema>/<blob id>` and the per-app erase resolves its sweep prefix from the
    /// schema name with no mapping table in between, so a slug that differed would park this
    /// app's recordings where the erase never reaches. Pinned by the blob contract suite.
    public static let postgresSchema = "transcriptionstudio"

    /// `<app>.<version>`. Bumped only when a migration changes what a row *means on the wire*;
    /// the engine turns that declaration into a deliberate mark-all-dirty enrollment push.
    public static let version = "transcriptionstudio.1"

    /// Parents before children, so a session and its segments pulled in the same cycle resolve
    /// their links on the same pass. `mac_presence` has no parent and sorts last.
    ///
    /// Main-actor isolated because `SyncTable.of` erases a `@Model`'s members into closures, and
    /// those are main-actor for the same reason the engine is: `StoreHistoryReader` is.
    @MainActor public static let schema = SyncSchema(
        version: version,
        tables: [
            .of(TranscriptSession.self),
            .of(StoredSegment.self),
            .of(TranscriptDecision.self),
            .of(TranscriptActionItem.self),
            .of(TranscriptEvent.self),
            .of(TranscriptPerson.self),
            .of(TranscriptPlace.self),
            .of(SpeakerAssignment.self),
            .of(MacPresence.self),
        ]
    )
}

// MARK: - Shared helpers

/// The session-child half of the single-parent contract, shared by every model whose one parent
/// is the `TranscriptSession` hub: relink attaches children to sessions that have since arrived.
///
/// A child can legitimately reach a device before the session it names — LWW is ordered by server
/// arrival and the tables page separately — so an unresolved link is an ordinary state, carried in
/// the engine's state file and retried on every apply until the parent lands.
protocol TranscriptSessionChild: AnyObject {
    var session: TranscriptSession? { get set }
}

@MainActor
func relinkSessionChildren<Child: SyncedModel & TranscriptSessionChild>(
    _ type: Child.Type,
    _ pairs: [UUID: UUID],
    in context: ModelContext
) throws -> Set<UUID> {
    guard !pairs.isEmpty else { return [] }
    var sessions: [UUID: TranscriptSession] = [:]
    for session in try context.fetch(TranscriptSession.descriptor(forSyncIDs: Array(Set(pairs.values)))) {
        sessions[session.id] = session
    }
    guard !sessions.isEmpty else { return [] }

    var resolved: Set<UUID> = []
    for child in try context.fetch(Child.descriptor(forSyncIDs: Array(pairs.keys))) {
        guard let sessionID = pairs[child.syncID], let session = sessions[sessionID] else { continue }
        if child.session !== session { child.session = session }
        resolved.insert(child.syncID)
    }
    return resolved
}

/// The child half of `syncRow`/`apply` every session child repeats: the parent's uuid out, and the
/// detach-or-defer decision in.
extension TranscriptSessionChild {
    var sessionLink: JSONValue { session.map { .string($0.id.uuidString) } ?? .null }

    /// Detaching is context-free and happens inline; attaching is not, because the session may not
    /// have arrived yet — so a present, non-null link is handed back for the applier to resolve.
    func applySessionLink(_ row: [String: JSONValue]) -> UUID? {
        guard let link = row["session_id"] else { return nil }
        guard let sessionID = link.uuidValue else {
            session = nil
            return nil
        }
        return sessionID
    }
}

// MARK: - TranscriptSession

extension TranscriptSession: SyncedModel {
    public static var syncTableName: String { "transcriptionstudio.transcript_session" }
    public static var syncIDKeyPath: KeyPath<TranscriptSession, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<TranscriptSession> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<TranscriptSession> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<TranscriptSession> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(title: "", kind: .fileTranscription)
        id = syncID
    }

    /// Enum-backed `kind`/`status`/`highlights_status` ride as their raw strings, verbatim — a
    /// value from a newer client survives the round trip unchanged and the typed wrapper degrades
    /// gracefully locally. `audio` is the staged `AssetSource` (rule 7); the pre-staging bytes in
    /// `audioData` never ride, and neither does the derived `daySectionKey`.
    public func syncRow() -> [String: JSONValue] {
        [
            "title": .string(title),
            "kind": .string(kindRaw),
            "status": .string(statusRaw),
            "created_at": .date(createdAt),
            "source_url": sourceURLString.map(JSONValue.string) ?? .null,
            "audio": audioAsset?.jsonValue ?? .null,
            "duration": .double(duration),
            "full_text": .string(fullText),
            "error_message": errorMessage.map(JSONValue.string) ?? .null,
            "is_private": .bool(isPrivate),
            "location_name": locationName.map(JSONValue.string) ?? .null,
            "latitude": coordinate.map { .double($0.latitude) } ?? .null,
            "longitude": coordinate.map { .double($0.longitude) } ?? .null,
            "claimed_at": claimedAt.map(JSONValue.date) ?? .null,
            "claimed_by": claimedBy.map(JSONValue.string) ?? .null,
            "highlights_status": .string(highlightsStatusRaw),
            "dismissed_suggestion_ids": .array(dismissedSuggestionIDs.map(JSONValue.string)),
        ]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        // Present-key-only assignment, and every unlisted key ignored — the additive-evolution
        // bargain's client half. An unknown column must not throw, or one server-side addition
        // becomes a breaking change for every shipped client.
        if let value = row["title"]?.stringValue { title = value }
        if let value = row["kind"]?.stringValue { kindRaw = value }
        if let value = row["status"]?.stringValue { statusRaw = value }
        if let value = row["created_at"]?.dateValue { adoptCreatedAt(value) }
        if let value = row["source_url"] { sourceURLString = value.stringValue }
        if let value = row["audio"] { audioAsset = AssetSource(jsonValue: value) }
        if let value = row["duration"]?.doubleValue { duration = value }
        if let value = row["full_text"]?.stringValue { fullText = value }
        if let value = row["error_message"] { errorMessage = value.stringValue }
        if let value = row["is_private"]?.boolValue { isPrivate = value }
        if let value = row["location_name"] { locationName = value.stringValue }
        // Two columns, one value: a coordinate exists only when both halves do, so a partial row
        // (one column added, one still null) leaves no half-placed pin on the map.
        if row["latitude"] != nil || row["longitude"] != nil {
            let latitude = row["latitude"]?.doubleValue ?? coordinate?.latitude
            let longitude = row["longitude"]?.doubleValue ?? coordinate?.longitude
            if let latitude, let longitude, row["latitude"]?.isNull != true, row["longitude"]?.isNull != true {
                coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
            } else {
                coordinate = nil
            }
        }
        if let value = row["claimed_at"] { claimedAt = value.dateValue }
        if let value = row["claimed_by"] { claimedBy = value.stringValue }
        if let value = row["highlights_status"]?.stringValue { highlightsStatusRaw = value }
        if let value = row["dismissed_suggestion_ids"]?.stringArray { dismissedSuggestionIDs = value }
        return nil
    }
}

// MARK: - StoredSegment

extension StoredSegment: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.stored_segment" }
    public static var syncIDKeyPath: KeyPath<StoredSegment, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<StoredSegment> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<StoredSegment> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<StoredSegment> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(start: 0, end: 0, text: "")
        id = syncID
    }

    /// `words` crosses as the structured JSON it already is, not as opaque bytes: `wordsJSON` is
    /// `JSONEncoder` output over `[AsrWord]`, so decoding it into the wire keeps the column a real
    /// `jsonb` a query can reach rather than a base64 string nothing can read.
    public func syncRow() -> [String: JSONValue] {
        [
            "start": .double(start),
            "end": .double(end),
            "text": .string(text),
            "track": .string(trackRaw),
            "speaker_slot": .int(Int64(speakerSlot)),
            "speaker_confidence": .double(Double(speakerConfidence)),
            "avg_logprob": .double(Double(avgLogprob)),
            "no_speech_prob": .double(Double(noSpeechProb)),
            "compression_ratio": .double(Double(compressionRatio)),
            "words": words.map(JSONValue.encoding) ?? .null,
            "session_id": sessionLink,
        ]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["start"]?.doubleValue { start = value }
        if let value = row["end"]?.doubleValue { end = value }
        if let value = row["text"]?.stringValue { text = value }
        if let value = row["track"]?.stringValue { trackRaw = value }
        if let value = row["speaker_slot"]?.intValue { speakerSlot = Int(value) }
        if let value = row["speaker_confidence"]?.doubleValue { speakerConfidence = Float(value) }
        if let value = row["avg_logprob"]?.doubleValue { avgLogprob = Float(value) }
        if let value = row["no_speech_prob"]?.doubleValue { noSpeechProb = Float(value) }
        if let value = row["compression_ratio"]?.doubleValue { compressionRatio = Float(value) }
        if let value = row["words"] { words = value.decoded(as: [AsrWord].self) }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - TranscriptDecision

extension TranscriptDecision: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.transcript_decision" }
    public static var syncIDKeyPath: KeyPath<TranscriptDecision, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<TranscriptDecision> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<TranscriptDecision> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<TranscriptDecision> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(text: "")
        id = syncID
    }

    public func syncRow() -> [String: JSONValue] {
        ["text": .string(text), "session_id": sessionLink]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["text"]?.stringValue { text = value }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - TranscriptActionItem

extension TranscriptActionItem: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.transcript_action_item" }
    public static var syncIDKeyPath: KeyPath<TranscriptActionItem, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<TranscriptActionItem> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<TranscriptActionItem> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<TranscriptActionItem> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(task: "")
        id = syncID
    }

    public func syncRow() -> [String: JSONValue] {
        [
            "task": .string(task),
            "owner": owner.map(JSONValue.string) ?? .null,
            "due_date_text": dueDateText.map(JSONValue.string) ?? .null,
            "due_date": dueDate.map(JSONValue.date) ?? .null,
            "done": .bool(done),
            "session_id": sessionLink,
        ]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["task"]?.stringValue { task = value }
        if let value = row["owner"] { owner = value.stringValue }
        if let value = row["due_date_text"] { dueDateText = value.stringValue }
        if let value = row["due_date"] { dueDate = value.dateValue }
        if let value = row["done"]?.boolValue { done = value }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - TranscriptEvent

extension TranscriptEvent: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.transcript_event" }
    public static var syncIDKeyPath: KeyPath<TranscriptEvent, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<TranscriptEvent> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<TranscriptEvent> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<TranscriptEvent> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(title: "")
        id = syncID
    }

    public func syncRow() -> [String: JSONValue] {
        [
            "title": .string(title),
            "date_text": .string(dateText),
            "date": date.map(JSONValue.date) ?? .null,
            "attendees": .array(attendees.map(JSONValue.string)),
            "session_id": sessionLink,
        ]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["title"]?.stringValue { title = value }
        if let value = row["date_text"]?.stringValue { dateText = value }
        if let value = row["date"] { date = value.dateValue }
        if let value = row["attendees"]?.stringArray { attendees = value }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - TranscriptPerson

extension TranscriptPerson: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.transcript_person" }
    public static var syncIDKeyPath: KeyPath<TranscriptPerson, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<TranscriptPerson> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<TranscriptPerson> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<TranscriptPerson> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(name: "")
        id = syncID
    }

    public func syncRow() -> [String: JSONValue] {
        ["name": .string(name), "session_id": sessionLink]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["name"]?.stringValue { name = value }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - TranscriptPlace

extension TranscriptPlace: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.transcript_place" }
    public static var syncIDKeyPath: KeyPath<TranscriptPlace, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<TranscriptPlace> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<TranscriptPlace> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<TranscriptPlace> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(name: "")
        id = syncID
    }

    public func syncRow() -> [String: JSONValue] {
        ["name": .string(name), "session_id": sessionLink]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["name"]?.stringValue { name = value }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - SpeakerAssignment

extension SpeakerAssignment: SyncedModel, TranscriptSessionChild {
    public static var syncTableName: String { "transcriptionstudio.speaker_assignment" }
    public static var syncIDKeyPath: KeyPath<SpeakerAssignment, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<SpeakerAssignment> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<SpeakerAssignment> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<SpeakerAssignment> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(speakerSlot: 0, contactIdentifier: "", displayName: "")
        id = syncID
    }

    /// `contact_identifier` is a `CNContact.identifier` — a *local* Contacts handle. It rides so a
    /// re-bind on the other device can re-resolve when the same contact exists there, and
    /// `display_name` is the denormalized copy that makes the label and the Spotlight index work
    /// when it does not.
    public func syncRow() -> [String: JSONValue] {
        [
            "speaker_slot": .int(Int64(speakerSlot)),
            "contact_identifier": .string(contactIdentifier),
            "display_name": .string(displayName),
            "session_id": sessionLink,
        ]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["speaker_slot"]?.intValue { speakerSlot = Int(value) }
        if let value = row["contact_identifier"]?.stringValue { contactIdentifier = value }
        if let value = row["display_name"]?.stringValue { displayName = value }
        return applySessionLink(row)
    }

    public static func relink(_ pairs: [UUID: UUID], in context: ModelContext) throws -> Set<UUID> {
        try relinkSessionChildren(Self.self, pairs, in: context)
    }
}

// MARK: - MacPresence

extension MacPresence: SyncedModel {
    public static var syncTableName: String { "transcriptionstudio.mac_presence" }
    public static var syncIDKeyPath: KeyPath<MacPresence, UUID> { \.id }

    public static func descriptor(forSyncIDs ids: [UUID]) -> FetchDescriptor<MacPresence> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.id) })
    }

    public static func descriptor(forPersistentIDs ids: [PersistentIdentifier]) -> FetchDescriptor<MacPresence> {
        FetchDescriptor(predicate: #Predicate { ids.contains($0.persistentModelID) })
    }

    public static var allRecordsDescriptor: FetchDescriptor<MacPresence> { FetchDescriptor() }

    public convenience init(syncID: UUID) {
        self.init(deviceIDString: "", deviceName: "")
        id = syncID
    }

    /// The one rootless synced record: a device's own liveness, with exactly one writer per row.
    public func syncRow() -> [String: JSONValue] {
        [
            "device_id": .string(deviceIDString),
            "device_name": .string(deviceName),
            "last_seen": .date(lastSeen),
        ]
    }

    @discardableResult
    public func apply(_ row: [String: JSONValue]) -> UUID? {
        if let value = row["device_id"]?.stringValue { deviceIDString = value }
        if let value = row["device_name"]?.stringValue { deviceName = value }
        if let value = row["last_seen"]?.dateValue { lastSeen = value }
        return nil
    }
}
