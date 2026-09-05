import FCTBlobSync
import Foundation
import SwiftData

/// How a session came to exist — drives which surfaces/actions apply.
enum SessionKind: String, Sendable, Codable, CaseIterable {
    case urlTranscription      // yt-dlp ingest (Mac)
    case fileTranscription     // dropped/picked media file
    case roomRecording         // live mic capture
    case meetingRecording      // live system + mic capture (Mac)
}

enum SessionStatus: String, Sendable, Codable, CaseIterable {
    case inProgress            // recording or transcribing now
    case pendingRemote         // a link queued from iOS, awaiting a Mac to claim + transcribe
    case complete
    case failed
}

/// A stored geographic coordinate — the raw lat/long behind a session's opt-in recording-location
/// metadata. Persisted as a SwiftData Codable attribute (`TranscriptSession.coordinate`); kept a
/// plain `Codable` value type rather than a `@Model` because it's framework-owned data with no
/// query need (roadmap §11/§12). `Sendable` so it crosses the location provider's task boundaries.
struct GeoCoordinate: Codable, Sendable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One transcription/recording session — the library's unit, and the root every other synced
/// record hangs off. Defaults on every attribute, optional to-many with an inverse.
@Model
final class TranscriptSession {
    #Index<TranscriptSession>([\.createdAt], [\.kindRaw, \.createdAt])

    // The record's cross-device name. `.unique` is what the applier's upsert-by-uuid rests on:
    // two rows for one uuid would break the operation the whole read path is built on, and
    // without the constraint nothing on the device would ever say so. `.preserveValueOnDeletion`
    // keeps the UUID in the SwiftData history tombstone after the row is gone, so a deletion is
    // pushable at all — and so the incremental Spotlight observer can recover a deleted session's
    // stable id and deindex it (the `PersistentIdentifier` is local-only and useless once the
    // model is gone). See `SpotlightIndexObserver`.
    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Stored per-calendar-day key for native `@Query(sectionBy:)` (SDK 27) on the home feed,
    /// derived from `createdAt` at creation (see `init`). It must be a *stored* property:
    /// `@Query(sectionBy:)` sections at the store level and traps on a computed key path. An ISO
    /// `yyyy-MM-dd` string (current calendar/time zone) so it groups a day's sessions and, ordered
    /// like the calendar, keeps day sections newest-first under the `createdAt`-descending sort.
    /// `createdAt` is a creation-time stamp the app never reassigns, so deriving once at `init`
    /// keeps this correct; the feed reads the *human* header off each section's own sessions, so
    /// this only has to group.
    private(set) var daySectionKey: String = ""
    var title: String = ""
    var kindRaw: String = SessionKind.fileTranscription.rawValue
    var statusRaw: String = SessionStatus.inProgress.rawValue
    /// Source URL string for URL transcriptions; nil otherwise.
    var sourceURLString: String?

    // MARK: The recording — the two-column pre-account shape (model contract rule 7)
    //
    // The bytes of a recording are AUTHORED: they exist only because the user made them, there
    // is no canon but ours, and losing them loses the record. So they sync — through
    // `FCTBlobSync`, never as a record column.
    //
    // The app is fully usable before an account exists and there is no blob store to stage into
    // then, so the recording lives in TWO columns with one invariant across them: **at most one
    // is non-nil**. Capture writes `audioData` only; the enrollment/staging sweep
    // (`TranscriptionSync.stageAuthoredAudio`) is the ONLY writer that moves a session across —
    // stage the bytes, write `audioAsset = .authored(ref)`, clear `audioData`, in one save — and
    // every reader prefers the asset and falls back to the bytes (`archivedAudio`). Nothing in
    // the type system enforces this; the discipline is the whole of it.

    /// The archived session audio as compressed AAC/m4a data, **before** it has been staged into
    /// the blob layer. Local-only and never serialized to the wire: this is the pre-staging
    /// holder, not a second copy of a staged recording.
    @Attribute(.externalStorage) var audioData: Data?

    /// The staged recording, once the blob layer holds it: `.authored(BlobRef)`, whose full bytes
    /// live in object storage and a permanent local cache, and whose ref rides this record.
    ///
    /// **Fetch-on-demand, and for audio that is not a tuning knob.** A recording encodes at 32
    /// kbps mono AAC (`AudioFileIO`) = **4 KB/s = ~14.4 MB per hour**, uncapped by anything but
    /// how long someone spoke. A modest daily-driver library — 200 sessions averaging 30 minutes
    /// — is ~100 hours, **~1.4 GB of authored audio**. Against the tier this ships on (1 GB
    /// storage · 50 MB per file · **5 GB egress/month**), every-device-eager fetching spends
    /// ~1.4 GB of egress *per enrolled device per full pass*: two devices, or one reinstall,
    /// burns over half the month, and the library is already past the storage tier on its own.
    /// Lazy costs a fetch per *listen* instead — a small fraction of a personal corpus, because
    /// nobody re-plays a library they only read.
    ///
    /// What makes lazy honest here rather than a degradation: the transcript is a **record**, not
    /// a blob. Title, duration, date, and the full segment text all arrive by ordinary record
    /// sync, so a reinstalled device renders the whole library and every word of every transcript
    /// with zero storage egress; the audio is the one thing that waits for a tap on play.
    ///
    /// **No preview.** `BlobRef.preview` is typed-optional and this app ships none: an audio
    /// recording has no thumbnail, and a waveform would be a *derived* artifact — rebuildable
    /// from bytes we already hold — bought at 5–20 KB on every session row for a decorative
    /// glyph. The list cell renders from the synced metadata it already has.
    ///
    /// **The one hard edge, stated rather than discovered:** the bucket caps a single object at
    /// 50 MB, which at 32 kbps is **~3.5 hours** of continuous recording. A longer session is
    /// refused at *stage* time, so it never enters the upload queue: it keeps its audio in
    /// ``audioData`` on the device that recorded it, and the sweep passes over it and stages the
    /// sessions behind it. Its record, transcript, segments and highlights all sync as usual.
    ///
    /// Stored as text because `AssetSource` cannot be a stored property: SwiftData describes a
    /// property by reflecting its type's shape rather than by running its `Codable` conformance,
    /// and this one's is hand-written for the discriminated wire shape — which compiles clean and
    /// dies at the first save. ``audioAsset`` is its typed face.
    var audioAssetText: String?

    var duration: TimeInterval = 0
    /// The full plain-text transcript, denormalized for fast search/copy.
    var fullText: String = ""
    var errorMessage: String?

    /// Per-session privacy lock. When set, opening this session's transcript requires a
    /// biometric (Face ID / Touch ID, device-passcode fallback) unlock, and the session is
    /// withheld from the assistant surface — never Spotlight-indexed, never donated as a
    /// relevant entity, never returned by a Siri/App-Intent library query. See `PrivacyGate` and
    /// `Documentation/PRIVACY-LOCK.md` (which also documents why a private session's rows and
    /// recording still sync).
    var isPrivate: Bool = false

    /// Opt-in recording-location metadata (roadmap §11). A short human place name resolved by
    /// reverse geocoding once at live-recording start (`RecordingLocationProvider`), folded into
    /// the Spotlight keywords (`SessionKeywords`) so "the meeting at the office" recalls the
    /// session. `nil` unless the user turned location capture on *and* a fix resolved — a denied
    /// permission or failed fix degrades silently to no location.
    var locationName: String?
    /// The raw coordinate behind `locationName`, backing the Maps deep-link chip. A SwiftData
    /// Codable attribute — the blessed use of that escape hatch for a framework-owned value with
    /// no query need (§11/§12), unlike the extracted-highlight `@Model`s.
    var coordinate: GeoCoordinate?

    /// Companion claim marker. When a Mac claims a `.pendingRemote` link to transcribe it, it
    /// stamps the claim time here and moves the session to `.inProgress`; `nil` for every
    /// locally-created session (which is how the watcher tells a claimed remote job from a Mac's
    /// own local URL job). Paired with `claimedBy` so a stalled claim can be reclaimed. See
    /// `RemoteJobClaim`.
    var claimedAt: Date?
    /// The stable identifier of the device that claimed this remote job; `nil` until claimed.
    var claimedBy: String?

    /// Where this session stands in the Foundation Models extraction pass. Drives whether the
    /// detail view shows extracted highlights; degrades to `.unavailable` (quiet, not an error)
    /// when Apple Intelligence can't run. See `HighlightsExtractor`.
    var highlightsStatusRaw: String = HighlightsStatus.pending.rawValue

    /// Suggestion chips the user waved away — the stable per-item ids ("event:<uuid>", …) from
    /// `ActionSuggestions`, so a dismissed chip never resurfaces for this session. Per item,
    /// never a session-wide switch; a plain string array like `attendees`,
    /// so dismissals sync across devices with the session.
    var dismissedSuggestionIDs: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredSegment.session)
    var segments: [StoredSegment]? = []

    // MARK: Extracted highlights (the FM extraction substrate — real queryable models, not blobs)

    @Relationship(deleteRule: .cascade, inverse: \TranscriptDecision.session)
    var decisions: [TranscriptDecision]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptActionItem.session)
    var actionItems: [TranscriptActionItem]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptEvent.session)
    var events: [TranscriptEvent]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptPerson.session)
    var people: [TranscriptPerson]? = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptPlace.session)
    var places: [TranscriptPlace]? = []

    // MARK: Speaker → contact bindings (Phase 3 — speaker mapping)

    @Relationship(deleteRule: .cascade, inverse: \SpeakerAssignment.session)
    var speakerAssignments: [SpeakerAssignment]? = []

    var highlightsStatus: HighlightsStatus {
        get { HighlightsStatus(rawValue: highlightsStatusRaw) ?? .pending }
        set { highlightsStatusRaw = newValue.rawValue }
    }

    /// The staged recording's typed face over ``audioAssetText``.
    var audioAsset: AssetSource? {
        get { audioAssetText.flatMap(AssetSource.init(storedText:)) }
        set { audioAssetText = newValue?.storedText }
    }

    var kind: SessionKind {
        get { SessionKind(rawValue: kindRaw) ?? .fileTranscription }
        set { kindRaw = newValue.rawValue }
    }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    init(title: String, kind: SessionKind, createdAt: Date = Date()) {
        self.title = title
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.daySectionKey = DaySectionKey.string(for: createdAt)
    }

    /// Reassign the creation stamp and re-derive ``daySectionKey`` with it — the one path that may
    /// move `createdAt` after `init`, and the sync applier's entry point for a pulled `created_at`.
    ///
    /// The two must move together: `@Model` silently drops property observers, so a `didSet` on
    /// `createdAt` would compile and never run, and the feed would section a pulled session under
    /// the day it arrived rather than the day it was recorded. `daySectionKey` is derived, so it
    /// never rides the wire.
    func adoptCreatedAt(_ date: Date) {
        createdAt = date
        daySectionKey = DaySectionKey.string(for: date)
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
final class StoredSegment {
    #Index<StoredSegment>([\.start])

    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var start: TimeInterval = 0
    var end: TimeInterval = 0
    var text: String = ""
    var trackRaw: String = AudioTrack.mixed.rawValue
    /// SpeakerID flattened: -2 unknown, -1 me, 0–3 diarized slot.
    var speakerSlot: Int = -2
    var speakerConfidence: Float = 0
    var avgLogprob: Float = 0
    /// JSON-encoded [AsrWord] when word timestamps were captured.
    var wordsJSON: Data?

    var session: TranscriptSession?

    var speaker: SpeakerID {
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

    /// The captured word timestamps behind ``wordsJSON``. `nil` when none were captured
    /// (`AppSettings.wordTimestamps` is off by default) — the per-word confidence view degrades to
    /// the per-segment score, which is a whole state rather than an error.
    var words: [AsrWord]? {
        get { wordsJSON.flatMap { try? JSONDecoder().decode([AsrWord].self, from: $0) } }
        set { wordsJSON = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    convenience init(from attributed: AttributedSegment) {
        self.init(start: attributed.asr.start, end: attributed.asr.end, text: attributed.asr.text)
        trackRaw = attributed.asr.track.rawValue
        speaker = attributed.speaker
        speakerConfidence = attributed.speakerConfidence
        avgLogprob = attributed.asr.avgLogprob
        words = attributed.asr.words
    }
}

/// A device's last-seen heartbeat, so the *other* device can show a presence indicator. The Mac
/// companion writes/updates its own row every heartbeat while running; iOS reads the most recent
/// `lastSeen` to tell whether a Mac is currently available to process queued links. Status
/// display only — it never gates queuing.
///
/// **It is the one row on this app's wire whose write rate is a clock rather than a user
/// intention**, and that is worth knowing before reading the feed: one push a minute per running
/// Mac, each advancing the account's `updated_seq` and nudging every other device to pull. LWW is
/// vacuous on it (exactly one device ever writes its own row, matched by `deviceIDString`), so it
/// costs round trips and never correctness.
///
/// `deviceIDString` keys the per-device upsert and is deliberately a plain attribute: `id` is the
/// record's cross-device name, and a second unique constraint would make a re-installed device
/// reusing its identifier a migration failure rather than an ordinary upsert.
@Model
final class MacPresence {
    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    /// The stable per-install device identifier this heartbeat belongs to.
    var deviceIDString: String = ""
    /// A human-readable device name for the presence label (e.g. "Fernando's Mac").
    var deviceName: String = ""
    var lastSeen: Date = Date()

    init(deviceIDString: String, deviceName: String, lastSeen: Date = Date()) {
        self.deviceIDString = deviceIDString
        self.deviceName = deviceName
        self.lastSeen = lastSeen
    }
}
