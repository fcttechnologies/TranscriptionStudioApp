import Foundation

/// The inert, reviewable description of a Calendar event we're about to create — the ``ConfirmableWrite``
/// `Draft` for a calendar write. Built deterministically from an extracted `TranscriptEvent`; shown
/// (and lightly editable) in the confirm sheet; nothing is written until the user confirms.
struct CalendarDraft: Equatable, Sendable {
    var title: String
    var startDate: Date
    var endDate: Date
    var notes: String

    init(title: String, startDate: Date, endDate: Date, notes: String) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }
}

/// The reviewable description of a Reminder we're about to create — the `Draft` for a reminders write.
/// Built from an extracted `TranscriptActionItem`; `dueDate` is nil when the action item carried no
/// resolvable date (the reminder is created with no due date rather than a guessed one).
struct ReminderDraft: Equatable, Sendable {
    var title: String
    var notes: String
    var dueDate: Date?

    init(title: String, notes: String, dueDate: Date? = nil) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
    }
}

/// Deterministic mapping from the FM-extracted `@Model` highlights to the Calendar/Reminders drafts —
/// pure Swift, no EventKit, no store, directly unit-testable. The model's `date`/`dueDate` were
/// already resolved to concrete `Date`s upstream by `RelativeDateResolver`; this layer only shapes
/// the fields (default duration, attribution notes) the confirm sheet then shows.
enum EventDraftMapper {
    /// Default length for an event whose end time wasn't extracted — one hour.
    static let defaultEventDuration: TimeInterval = 3600

    /// A `TranscriptEvent` → a `CalendarDraft`. When the event has no resolved `date`, the draft
    /// starts at the next whole hour after `now` (a sensible, user-editable default) and the
    /// originally-spoken phrase is preserved in the notes so the user can correct the time.
    static func calendarDraft(title: String, date: Date?, dateText: String,
                                     attendees: [String], sessionTitle: String,
                                     now: Date = Date(), calendar: Calendar = .current) -> CalendarDraft {
        let start = date ?? nextHour(after: now, calendar: calendar)
        let end = start.addingTimeInterval(defaultEventDuration)
        var lines: [String] = []
        if !attendees.isEmpty {
            lines.append("Attendees: " + attendees.joined(separator: ", "))
        }
        if date == nil {
            let phrase = dateText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { lines.append("Mentioned time: \(phrase)") }
        }
        lines.append(attribution(sessionTitle))
        return CalendarDraft(title: cleanTitle(title), startDate: start, endDate: end,
                             notes: lines.joined(separator: "\n"))
    }

    /// A `TranscriptActionItem` → a `ReminderDraft`. The owner (if any) and the originally-spoken due
    /// phrase (when no concrete date resolved) are preserved in the notes.
    static func reminderDraft(task: String, owner: String?, dueDate: Date?, dueDateText: String?,
                                     sessionTitle: String) -> ReminderDraft {
        var lines: [String] = []
        if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            lines.append("Owner: \(owner)")
        }
        if dueDate == nil, let phrase = dueDateText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !phrase.isEmpty {
            lines.append("Mentioned due: \(phrase)")
        }
        lines.append(attribution(sessionTitle))
        return ReminderDraft(title: cleanTitle(task), notes: lines.joined(separator: "\n"), dueDate: dueDate)
    }

    // MARK: - Convenience over the @Model types

    /// The `@Model` overload used by the app; reads the event's stored fields and defers to the pure
    /// core above.
    static func calendarDraft(for event: TranscriptEvent, sessionTitle: String,
                                     now: Date = Date()) -> CalendarDraft {
        calendarDraft(title: event.title, date: event.date, dateText: event.dateText,
                      attendees: event.attendees, sessionTitle: sessionTitle, now: now)
    }

    /// The `@Model` overload used by the app.
    static func reminderDraft(for item: TranscriptActionItem, sessionTitle: String) -> ReminderDraft {
        reminderDraft(task: item.task, owner: item.owner, dueDate: item.dueDate,
                      dueDateText: item.dueDateText, sessionTitle: sessionTitle)
    }

    // MARK: - Helpers

    static func attribution(_ sessionTitle: String) -> String {
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "From a Transcription Studio recording"
                               : "From transcript: \(trimmed)"
    }

    /// The next whole hour strictly after `date` — e.g. 2:15 → 3:00, 3:00 → 4:00.
    static func nextHour(after date: Date, calendar: Calendar = .current) -> Date {
        let flooredHour = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: flooredHour) ?? date.addingTimeInterval(defaultEventDuration)
    }

    private static func cleanTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
