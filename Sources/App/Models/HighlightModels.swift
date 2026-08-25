import Foundation
import SwiftData

/// Where a session stands in the Foundation Models extraction pass, so the UI can show extracted
/// highlights only once they're ready and degrade silently (no highlights, never an error state)
/// when Apple Intelligence isn't available — matching `SessionIntelligence`'s degrade-gracefully
/// posture.
enum HighlightsStatus: String, Sendable, Codable, CaseIterable {
    /// Not yet extracted (freshly saved, or extraction still running in the background).
    case pending
    /// Extraction ran and its results are persisted.
    case ready
    /// Apple Intelligence wasn't available, so no extraction ran — a quiet, non-error state.
    case unavailable
}

/// A key decision made in a conversation, one concise sentence. A real queryable `@Model` (not a
/// Codable blob) so "show me every decision across my meetings" is a plain SwiftData fetch. Every
/// attribute defaulted, optional inverse, identity is the UUID `id`.
@Model
final class TranscriptDecision {
    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var text: String = ""
    var session: TranscriptSession?

    init(text: String) {
        self.text = text
    }
}

/// A task or commitment someone made in a conversation. `dueDateText` is the phrase exactly as
/// spoken ("next Tuesday"); `dueDate` is the deterministically-resolved concrete date when one could
/// be parsed (see `RelativeDateResolver`). `done` makes an open-items view possible.
@Model
final class TranscriptActionItem {
    #Index<TranscriptActionItem>([\.dueDate], [\.done])

    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var task: String = ""
    /// Who is responsible, if stated; otherwise nil.
    var owner: String?
    /// The due date/time exactly as stated in the conversation ("next Tuesday", "by Friday").
    var dueDateText: String?
    /// The concrete date resolved from `dueDateText` against the session's date, when parseable.
    var dueDate: Date?
    var done: Bool = false
    var session: TranscriptSession?

    init(task: String, owner: String? = nil, dueDateText: String? = nil, dueDate: Date? = nil) {
        self.task = task
        self.owner = owner
        self.dueDateText = dueDateText
        self.dueDate = dueDate
    }
}

/// A meeting, event, or deadline mentioned with a time reference. `dateText` is the phrase as spoken;
/// `date` is the resolved concrete date when parseable. `attendees` is a plain string array —
/// names, not yet Contacts-bound (that's Phase 3).
@Model
final class TranscriptEvent {
    #Index<TranscriptEvent>([\.date])

    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var title: String = ""
    /// The date/time exactly as stated in the conversation.
    var dateText: String = ""
    /// The concrete date resolved from `dateText` against the session's date, when parseable.
    var date: Date?
    var attendees: [String] = []
    var session: TranscriptSession?

    init(title: String, dateText: String = "", date: Date? = nil, attendees: [String] = []) {
        self.title = title
        self.dateText = dateText
        self.date = date
        self.attendees = attendees
    }
}

/// A person mentioned by name or speaking in a conversation. A real `@Model` so name search and,
/// later, Contacts binding (Phase 3) have something to hang on.
@Model
final class TranscriptPerson {
    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    var session: TranscriptSession?

    init(name: String) {
        self.name = name
    }
}

/// A place or location mentioned in a conversation.
@Model
final class TranscriptPlace {
    @Attribute(.unique, .preserveValueOnDeletion) var id: UUID = UUID()
    var name: String = ""
    var session: TranscriptSession?

    init(name: String) {
        self.name = name
    }
}
