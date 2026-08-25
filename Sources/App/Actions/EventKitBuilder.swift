import Foundation
import EventKit

/// Builds the EventKit objects from a reviewed draft — the `Draft` → `EKEvent`/`EKReminder` field
/// mapping, isolated here so the field assignment is unit-testable (constructing `EKEvent`/`EKReminder`
/// needs no permission; only `save`/reading existing data does). The default-calendar assignment is
/// the one part that depends on granted access, and is verified on device.
enum EventKitBuilder {
    /// Populate a new event from `draft`. The calendar is the user's default for new events (nil until
    /// write access is granted — the caller checks before saving).
    static func makeEvent(from draft: CalendarDraft, in store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.notes = draft.notes
        event.calendar = store.defaultCalendarForNewEvents
        return event
    }

    /// Populate a new reminder from `draft`. A due date (when present) sets both the due components
    /// and an absolute alarm so the reminder actually notifies.
    static func makeReminder(from draft: ReminderDraft, in store: EKEventStore,
                             calendar: Calendar = .current) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = draft.dueDate {
            reminder.dueDateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        return reminder
    }
}

/// Why a Calendar/Reminders write couldn't complete — surfaced to the confirm sheet and to Siri.
enum EventKitWriteError: Error, LocalizedError, Equatable {
    /// The user declined (or hasn't granted) the minimal write access.
    case accessDenied
    /// No default calendar/list is configured to add to.
    case noDestination
    /// The underlying `save` failed.
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Transcription Studio doesn't have permission to add this. You can grant access in Settings."
        case .noDestination: "There's no default calendar or list to add this to."
        case .saveFailed: "That couldn't be saved. Please try again."
        }
    }
}
