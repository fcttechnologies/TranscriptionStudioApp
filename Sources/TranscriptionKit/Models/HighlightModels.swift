import Foundation
import SwiftData

/// Where a session stands in the Foundation Models extraction pass, so the UI can show extracted
/// highlights only once they're ready and degrade silently (no highlights, never an error state)
/// when Apple Intelligence isn't available — matching `SessionIntelligence`'s degrade-gracefully
/// posture.
public enum HighlightsStatus: String, Sendable, Codable, CaseIterable {
    /// Not yet extracted (freshly saved, or extraction still running in the background).
    case pending
    /// Extraction ran and its results are persisted.
    case ready
    /// Apple Intelligence wasn't available, so no extraction ran — a quiet, non-error state.
    case unavailable
}

/// A key decision made in a conversation, one concise sentence. A real queryable `@Model` (not a
/// Codable blob) so "show me every decision across my meetings" is a plain SwiftData fetch. CloudKit-
/// ready: every attribute defaulted, optional inverse, identity is the UUID `id`.
@Model
public final class TranscriptDecision {
    public var id: UUID = UUID()
    public var text: String = ""
    public var session: TranscriptSession?

    public init(text: String) {
        self.text = text
    }
}

/// A task or commitment someone made in a conversation. `dueDateText` is the phrase exactly as
/// spoken ("next Tuesday"); `dueDate` is the deterministically-resolved concrete date when one could
/// be parsed (see `RelativeDateResolver`). `done` makes an open-items view possible.
@Model
public final class TranscriptActionItem {
    #Index<TranscriptActionItem>([\.dueDate], [\.done])

    public var id: UUID = UUID()
    public var task: String = ""
    /// Who is responsible, if stated; otherwise nil.
    public var owner: String?
    /// The due date/time exactly as stated in the conversation ("next Tuesday", "by Friday").
    public var dueDateText: String?
    /// The concrete date resolved from `dueDateText` against the session's date, when parseable.
    public var dueDate: Date?
    public var done: Bool = false
    public var session: TranscriptSession?

    public init(task: String, owner: String? = nil, dueDateText: String? = nil, dueDate: Date? = nil) {
        self.task = task
        self.owner = owner
        self.dueDateText = dueDateText
        self.dueDate = dueDate
    }
}

/// A meeting, event, or deadline mentioned with a time reference. `dateText` is the phrase as spoken;
/// `date` is the resolved concrete date when parseable. `attendees` is a plain string array (CloudKit-
/// compatible) — names, not yet Contacts-bound (that's Phase 3).
@Model
public final class TranscriptEvent {
    #Index<TranscriptEvent>([\.date])

    public var id: UUID = UUID()
    public var title: String = ""
    /// The date/time exactly as stated in the conversation.
    public var dateText: String = ""
    /// The concrete date resolved from `dateText` against the session's date, when parseable.
    public var date: Date?
    public var attendees: [String] = []
    public var session: TranscriptSession?

    public init(title: String, dateText: String = "", date: Date? = nil, attendees: [String] = []) {
        self.title = title
        self.dateText = dateText
        self.date = date
        self.attendees = attendees
    }
}

/// A person mentioned by name or speaking in a conversation. A real `@Model` so name search and,
/// later, Contacts binding (Phase 3) have something to hang on.
@Model
public final class TranscriptPerson {
    public var id: UUID = UUID()
    public var name: String = ""
    public var session: TranscriptSession?

    public init(name: String) {
        self.name = name
    }
}

/// A place or location mentioned in a conversation.
@Model
public final class TranscriptPlace {
    public var id: UUID = UUID()
    public var name: String = ""
    public var session: TranscriptSession?

    public init(name: String) {
        self.name = name
    }
}
