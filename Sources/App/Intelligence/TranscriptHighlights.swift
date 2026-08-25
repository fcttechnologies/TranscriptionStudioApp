import Foundation
import FoundationModels

/// The transcript-domain `@Generable` extraction schema: what a Foundation Models guided-generation
/// pass pulls out of a completed transcript. This is the *transient* model output — a `Sendable`
/// value that crosses off the model's executor — which `HighlightsExtractor` then maps into the real,
/// queryable SwiftData `@Model` types (`TranscriptDecision`/`TranscriptActionItem`/… ) on the main
/// actor. The model's job is extraction only; concrete-date math stays in `RelativeDateResolver`.
@Generable(description: "Structured highlights extracted from a conversation transcript")
struct SessionHighlights: Sendable, Equatable {
    @Guide(description: "Key decisions the participants made, one concise sentence each. Omit if none.")
    var decisions: [String]

    @Guide(description: "Tasks or commitments someone agreed to do. Omit if none.")
    var actionItems: [ExtractedActionItem]

    @Guide(description: "Meetings, events, or deadlines mentioned with a date or time reference. Omit if none.")
    var events: [ExtractedEvent]

    @Guide(description: "People mentioned by name or speaking in the conversation. Names only. Omit if none.")
    var people: [String]

    @Guide(description: "Places or physical locations mentioned. Omit if none.")
    var places: [String]

    init(
        decisions: [String] = [],
        actionItems: [ExtractedActionItem] = [],
        events: [ExtractedEvent] = [],
        people: [String] = [],
        places: [String] = []
    ) {
        self.decisions = decisions
        self.actionItems = actionItems
        self.events = events
        self.people = people
        self.places = places
    }
}

/// A task or commitment as the model extracted it — the due date stays as the phrase spoken;
/// `RelativeDateResolver` turns it into a concrete date downstream (ordinary Swift, not the model).
@Generable
struct ExtractedActionItem: Sendable, Equatable {
    @Guide(description: "The task or commitment, one short sentence.")
    var task: String

    @Guide(description: "Who is responsible, if stated; otherwise leave empty.")
    var owner: String

    @Guide(description: "The due date/time exactly as stated, e.g. 'next Tuesday' or 'by Friday'. Empty if none.")
    var dueDateText: String

    init(task: String, owner: String = "", dueDateText: String = "") {
        self.task = task
        self.owner = owner
        self.dueDateText = dueDateText
    }
}

/// A meeting/event/deadline as the model extracted it. `dateText` stays as spoken; attendee names
/// only (Contacts binding is Phase 3).
@Generable
struct ExtractedEvent: Sendable, Equatable {
    @Guide(description: "A short title for the meeting, event, or deadline.")
    var title: String

    @Guide(description: "The date/time exactly as stated in the conversation. Empty if none.")
    var dateText: String

    @Guide(description: "Names of people expected to attend, if stated. Omit if none.")
    var attendees: [String]

    init(title: String, dateText: String = "", attendees: [String] = []) {
        self.title = title
        self.dateText = dateText
        self.attendees = attendees
    }
}
