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
    case complete
    case failed
}

/// One transcription/recording session — the library's unit. CloudKit-ready shape:
/// defaults on every attribute, optional to-many with an inverse, no unique constraints
/// (identity is the UUID `id`).
@Model
public final class TranscriptSession {
    #Index<TranscriptSession>([\.createdAt], [\.kindRaw, \.createdAt])

    public var id: UUID = UUID()
    public var createdAt: Date = Date()
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

    @Relationship(deleteRule: .cascade, inverse: \StoredSegment.session)
    public var segments: [StoredSegment]? = []

    public var kind: SessionKind {
        get { SessionKind(rawValue: kindRaw) ?? .fileTranscription }
        set { kindRaw = newValue.rawValue }
    }

    public var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    public init(title: String, kind: SessionKind) {
        self.title = title
        self.kindRaw = kind.rawValue
    }
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
