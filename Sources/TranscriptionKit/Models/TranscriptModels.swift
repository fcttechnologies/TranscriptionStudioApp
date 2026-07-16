import Foundation
import SwiftData

/// How a session came to exist — drives which surfaces/actions apply.
public enum SessionKind: String, Sendable, Codable, CaseIterable {
    case urlTranscription      // yt-dlp ingest (Mac)
    case fileTranscription     // dropped/picked media file
    case roomRecording         // live mic capture
    case meetingRecording      // live system + mic capture (Mac)
}

public enum SessionStatus: String, Sendable, Codable, CaseIterable {
    case inProgress            // recording or transcribing now
    case pendingRemote         // a link queued from iOS, awaiting a Mac to claim + transcribe
    case complete
    case failed
}

/// A stored geographic coordinate — the raw lat/long behind a session's opt-in recording-location
/// metadata. Persisted as a SwiftData Codable attribute (`TranscriptSession.coordinate`); kept a
/// plain `Codable` value type rather than a `@Model` because it's framework-owned data with no
/// query need (roadmap §11/§12). `Sendable` so it crosses the location provider's task boundaries.
public struct GeoCoordinate: Codable, Sendable, Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One transcription/recording session — the library's unit. CloudKit-ready shape:
/// defaults on every attribute, optional to-many with an inverse, no unique constraints
/// (identity is the UUID `id`).
@Model
public final class TranscriptSession {
    #Index<TranscriptSession>([\.createdAt], [\.kindRaw, \.createdAt])

    // `.preserveValueOnDeletion` keeps the UUID in the SwiftData history tombstone after the row
    // is gone, so the incremental Spotlight observer can recover a *synced* delete's stable id and
    // deindex it (the Spotlight identifier is `id.uuidString`; the PersistentIdentifier alone is
    // local-only and useless once the model is deleted). See `SpotlightIndexObserver`.
    @Attribute(.preserveValueOnDeletion) public var id: UUID = UUID()
    public var createdAt: Date = Date()
    /// Stored per-calendar-day key for native `@Query(sectionBy:)` (SDK 27) on the home feed,
    /// derived from `createdAt` at creation (see `init`). It must be a *stored* property:
    /// `@Query(sectionBy:)` sections at the store level and traps on a computed key path. An ISO
    /// `yyyy-MM-dd` string (current calendar/time zone) so it groups a day's sessions and, ordered
    /// like the calendar, keeps day sections newest-first under the `createdAt`-descending sort.
    /// `createdAt` is a creation-time stamp the app never reassigns, so deriving once at `init`
    /// keeps this correct; the feed reads the *human* header off each section's own sessions, so
    /// this only has to group. Defaulted + non-unique → CloudKit-safe.
    public private(set) var daySectionKey: String = ""
    public var title: String = ""
    public var kindRaw: String = SessionKind.fileTranscription.rawValue
    public var statusRaw: String = SessionStatus.inProgress.rawValue
    /// Source URL string for URL transcriptions; nil otherwise.
    public var sourceURLString: String?
    /// The archived session audio as compressed AAC/m4a data (re-playable and re-runnable
    /// through any engine — the offline verification loop). Stored externally (CKAsset under
    /// CloudKit sync) so the row stays light. Nil until archived.
    @Attribute(.externalStorage) public var audioData: Data?
    public var duration: TimeInterval = 0
    /// The full plain-text transcript, denormalized for fast search/copy.
    public var fullText: String = ""
    public var errorMessage: String?

    /// Per-session privacy lock. When set, opening this session's transcript requires a
    /// biometric (Face ID / Touch ID, device-passcode fallback) unlock, and the session is
    /// withheld from the assistant surface — never Spotlight-indexed, never donated as a
    /// relevant entity, never returned by a Siri/App-Intent library query. Defaulted (CloudKit-
    /// safe). See `PrivacyGate` and `Documentation/PRIVACY-LOCK.md` (which also documents why
    /// per-session CloudKit *sync* exclusion isn't cleanly achievable in this single-container
    /// architecture).
    public var isPrivate: Bool = false

    /// Opt-in recording-location metadata (roadmap §11). A short human place name resolved by
    /// reverse geocoding once at live-recording start (`RecordingLocationProvider`), folded into
    /// the Spotlight keywords (`SessionKeywords`) so "the meeting at the office" recalls the
    /// session. `nil` unless the user turned location capture on *and* a fix resolved — a denied
    /// permission or failed fix degrades silently to no location. Defaulted → CloudKit-safe.
    public var locationName: String?
    /// The raw coordinate behind `locationName`, backing the Maps deep-link chip. A SwiftData
    /// Codable attribute — the blessed use of that escape hatch for a framework-owned value with
    /// no query need (§11/§12), unlike the extracted-highlight `@Model`s. Defaulted → CloudKit-safe.
    public var coordinate: GeoCoordinate?

    /// Companion claim marker. When a Mac claims a `.pendingRemote` link to transcribe it, it
    /// stamps the claim time here and moves the session to `.inProgress`; `nil` for every
    /// locally-created session (which is how the watcher tells a claimed remote job from a Mac's
    /// own local URL job). Paired with `claimedBy` so a stalled claim can be reclaimed. See
    /// `RemoteJobClaim`.
    public var claimedAt: Date?
    /// The stable identifier of the device that claimed this remote job; `nil` until claimed.
    public var claimedBy: String?

    /// Where this session stands in the Foundation Models extraction pass. Drives whether the
    /// detail view shows extracted highlights; degrades to `.unavailable` (quiet, not an error)
    /// when Apple Intelligence can't run. See `HighlightsExtractor`.
    public var highlightsStatusRaw: String = HighlightsStatus.pending.rawValue

    /// Suggestion chips the user waved away — the stable per-item ids ("event:<uuid>", …) from
    /// `ActionSuggestions`, so a dismissed chip never resurfaces for this session. Per item,
    /// never a session-wide switch; a plain string array (CloudKit-compatible, like `attendees`)
    /// so dismissals sync across devices with the session.
    public var dismissedSuggestionIDs: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredSegment.session)
    public var segments: [StoredSegment]? = []

    // MARK: Extracted highlights (the FM extraction substrate — real queryable models, not blobs)

    @Relationship(deleteRule: .cascade, inverse: \TranscriptDecision.session)
    public var decisions: [TranscriptDecision]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptActionItem.session)
    public var actionItems: [TranscriptActionItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptEvent.session)
    public var events: [TranscriptEvent]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptPerson.session)
    public var people: [TranscriptPerson]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptPlace.session)
    public var places: [TranscriptPlace]? = []

    // MARK: Speaker → contact bindings (Phase 3 — speaker mapping)

    @Relationship(deleteRule: .cascade, inverse: \SpeakerAssignment.session)
    public var speakerAssignments: [SpeakerAssignment]? = []

    public var highlightsStatus: HighlightsStatus {
        get { HighlightsStatus(rawValue: highlightsStatusRaw) ?? .pending }
        set { highlightsStatusRaw = newValue.rawValue }
    }

    public var kind: SessionKind {
        get { SessionKind(rawValue: kindRaw) ?? .fileTranscription }
        set { kindRaw = newValue.rawValue }
    }

    public var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    public init(title: String, kind: SessionKind, createdAt: Date = Date()) {
        self.title = title
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.daySectionKey = DaySectionKey.string(for: createdAt)
    }
}

/// The `yyyy-MM-dd` day-key formatter behind `TranscriptSession.daySectionKey`, cached because
/// `DateFormatter` is expensive to build and this is evaluated per row while sectioning the feed.
enum DaySectionKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(for date: Date) -> String { formatter.string(from: date) }
}

/// One attributed transcript segment as persisted. Mirrors `AttributedSegment` flattened
/// for storage; the raw model confidences ride along so the inspector works on history,
/// not just live sessions.
@Model
public final class StoredSegment {
    #Index<StoredSegment>([\.start])

    public var id: UUID = UUID()
    public var start: TimeInterval = 0
    public var end: TimeInterval = 0
    public var text: String = ""
    public var trackRaw: String = AudioTrack.mixed.rawValue
    /// SpeakerID flattened: -2 unknown, -1 me, 0–3 diarized slot.
    public var speakerSlot: Int = -2
    public var speakerConfidence: Float = 0
    public var avgLogprob: Float = 0
    public var noSpeechProb: Float = 0
    public var compressionRatio: Float = 0
    /// JSON-encoded [AsrWord] when word timestamps were captured.
    public var wordsJSON: Data?

    public var session: TranscriptSession?

    public var speaker: SpeakerID {
        get {
            switch speakerSlot {
            case -1: .me
            case 0...: .speaker(speakerSlot)
            default: .unknown
            }
        }
        set {
            switch newValue {
            case .me: speakerSlot = -1
            case .speaker(let index): speakerSlot = index
            case .unknown: speakerSlot = -2
            }
        }
    }

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public convenience init(from attributed: AttributedSegment) {
        self.init(start: attributed.asr.start, end: attributed.asr.end, text: attributed.asr.text)
        trackRaw = attributed.asr.track.rawValue
        speaker = attributed.speaker
        speakerConfidence = attributed.speakerConfidence
        avgLogprob = attributed.asr.avgLogprob
        noSpeechProb = attributed.asr.noSpeechProb
        compressionRatio = attributed.asr.compressionRatio
        if let words = attributed.asr.words {
            wordsJSON = try? JSONEncoder().encode(words)
        }
    }
}

/// A device's last-seen heartbeat, written to the shared CloudKit store so the *other* device
/// can show a presence indicator. The Mac companion writes/updates its row every heartbeat while
/// running; iOS reads the most recent `lastSeen` to tell whether a Mac is currently available to
/// process queued links. Status display only — it never gates queuing. CloudKit-ready: every
/// attribute defaulted, no unique constraint (identity is the UUID `id`; `deviceIDString` keys
/// the per-device upsert).
@Model
public final class MacPresence {
    public var id: UUID = UUID()
    /// The stable per-install device identifier this heartbeat belongs to.
    public var deviceIDString: String = ""
    /// A human-readable device name for the presence label (e.g. "Fernando's Mac").
    public var deviceName: String = ""
    public var lastSeen: Date = Date()

    public init(deviceIDString: String, deviceName: String, lastSeen: Date = Date()) {
        self.deviceIDString = deviceIDString
        self.deviceName = deviceName
        self.lastSeen = lastSeen
    }
}
