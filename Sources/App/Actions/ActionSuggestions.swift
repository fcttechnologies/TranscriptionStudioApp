import Foundation
import SwiftData

/// One proactive suggestion — a single chip in the detail view's "Suggested" row, derived from
/// one extracted highlight (`TranscriptEvent`, `TranscriptActionItem`, or `TranscriptPerson`)
/// once the session's extraction pass is `.ready`. A pure value: the row renders it, and a tap
/// routes to the existing Phase 3 draft-then-confirm surface for its kind — a suggestion never
/// writes anything itself.
struct ActionSuggestion: Identifiable, Equatable, Sendable {
    /// Which Phase 3 confirm surface a tap opens.
    enum Kind: Equatable, Sendable {
        /// `CalendarDraftConfirmView` — review an extracted event before adding it to Calendar.
        case calendarEvent
        /// `ReminderDraftConfirmView` — review an extracted action item before adding a Reminder.
        case reminder
        /// `SpeakerAssignmentSheet` — bind speakers/mentions to real contacts (iOS only).
        case contact
    }

    /// Stable per-item identity ("event:<uuid>", …) — the value remembered in
    /// `TranscriptSession.dismissedSuggestionIDs`, so a dismissal survives re-derivation.
    let id: String
    let kind: Kind
    /// The extracted item's own text — the event title, the task, or the person's name.
    let detail: String
    /// The resolved concrete date to hint on the chip (event date / due date), when one exists.
    let date: Date?
    /// The backing `@Model`'s id, handed to the confirm sheet.
    let itemID: UUID
}

/// Derives a session's suggestion chips — the pure extraction→chip mapping (kinds, stable ids,
/// deterministic ordering, staleness/`done` filters) plus the per-item dismissal write. All of
/// it deterministic and unit-tested; the `SuggestedActionsRow` view is a thin renderer over it.
enum ActionSuggestions {
    static func eventSuggestionID(_ id: UUID) -> String { "event:\(id.uuidString)" }
    static func reminderSuggestionID(_ id: UUID) -> String { "reminder:\(id.uuidString)" }
    static func contactSuggestionID(_ id: UUID) -> String { "contact:\(id.uuidString)" }

    /// The chips to show for a session, in display order: Calendar events (soonest first,
    /// undated last), then Reminders, then contacts. Empty until the extraction pass is
    /// `.ready`; dismissed items stay gone. Filters, not just maps: an event whose resolved
    /// date already passed is stale (nothing to add to a calendar), while a past-due action
    /// item is still an open task and keeps its chip; `done` items are finished and get none.
    /// `includeContacts` is false where the contact surface doesn't exist (macOS).
    @MainActor
    static func suggestions(for session: TranscriptSession,
                                   includeContacts: Bool,
                                   now: Date = .now) -> [ActionSuggestion] {
        guard session.highlightsStatus == .ready else { return [] }
        let dismissed = Set(session.dismissedSuggestionIDs)
        var chips: [ActionSuggestion] = []

        let events = (session.events ?? [])
            .filter { $0.date.map { $0 >= now } ?? true }
            .sorted { ordered(($0.date, $0.title, $0.id), before: ($1.date, $1.title, $1.id)) }
        for event in events {
            chips.append(ActionSuggestion(id: eventSuggestionID(event.id), kind: .calendarEvent,
                                          detail: event.title, date: event.date, itemID: event.id))
        }

        let actionItems = (session.actionItems ?? [])
            .filter { !$0.done }
            .sorted { ordered(($0.dueDate, $0.task, $0.id), before: ($1.dueDate, $1.task, $1.id)) }
        for item in actionItems {
            chips.append(ActionSuggestion(id: reminderSuggestionID(item.id), kind: .reminder,
                                          detail: item.task, date: item.dueDate, itemID: item.id))
        }

        if includeContacts {
            let people = (session.people ?? [])
                .sorted { ordered((nil, $0.name, $0.id), before: (nil, $1.name, $1.id)) }
            for person in people {
                chips.append(ActionSuggestion(id: contactSuggestionID(person.id), kind: .contact,
                                              detail: person.name, date: nil, itemID: person.id))
            }
        }

        return chips.filter { !dismissed.contains($0.id) }
    }

    /// Remember a dismissal (or a served suggestion — a confirmed write dismisses its chip too)
    /// on the session. Idempotent; persists immediately so it survives relaunch and syncs.
    @MainActor
    static func dismiss(_ id: String, on session: TranscriptSession,
                               in modelContext: ModelContext) {
        guard !session.dismissedSuggestionIDs.contains(id) else { return }
        session.dismissedSuggestionIDs.append(id)
        try? modelContext.save()
    }

    /// Deterministic display order: dated before undated, sooner first, then by text, with the
    /// UUID as the final stable tie-break (SwiftData to-many arrays carry no order).
    private static func ordered(_ a: (Date?, String, UUID), before b: (Date?, String, UUID)) -> Bool {
        let aDate = a.0 ?? .distantFuture
        let bDate = b.0 ?? .distantFuture
        if aDate != bDate { return aDate < bDate }
        if a.1 != b.1 { return a.1 < b.1 }
        return a.2.uuidString < b.2.uuidString
    }
}
