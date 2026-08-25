import SwiftUI
import SwiftData
import FCTComponentsUI

/// **Draft-then-confirm — Calendar.** Reviews an extracted `TranscriptEvent` as an editable draft and,
/// only on an explicit tap, commits it through the generalized `ConfirmableWrite` boundary
/// (`CalendarWriteAction`), which requests the minimal write-only calendar scope and saves the event.
/// Nothing is written until the user taps Add. Reached from the shell's sheet routing (App Intents)
/// and from the detail view's suggestion chips (`SuggestedActionsRow`).
struct CalendarDraftConfirmView: View {
    let eventID: UUID
    /// Fires after a successful write, before this sheet dismisses — the suggestion-chip host
    /// uses it to retire the served chip. Nil (a no-op) from the shell's App Intent route.
    var onConfirmed: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var loaded = false
    @State private var saving = false
    @State private var title = ""
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                if loaded {
                    Section("Event") {
                        TextField("Title", text: $title)
                            .accessibilityIdentifier("calendarDraft.title")
                        DatePicker("Starts", selection: $startDate)
                        DatePicker("Ends", selection: $endDate, in: startDate...)
                    }
                    if !notes.isEmpty {
                        Section("Notes") {
                            Text(notes).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button { save() } label: {
                            Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("calendarDraft.add")
                    } footer: {
                        Text("Nothing is added until you tap Add. Transcription Studio only asks for permission to add — never to read your calendar.")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Add to Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        // A confirm failure surfaces an error toast while THIS sheet stays presented; the shared
        // overlay lives on the app root (occluded by the sheet), so install one on the sheet too.
        .withToast()
        #if os(macOS)
        .frame(width: DesignMetrics.macSheetSize.width, height: DesignMetrics.macSheetSize.height)
        #endif
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        let id = eventID
        var descriptor = FetchDescriptor<TranscriptEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let event = try? modelContext.fetch(descriptor).first else { dismiss(); return }
        let draft = EventDraftMapper.calendarDraft(for: event, sessionTitle: event.session?.title ?? "")
        title = draft.title
        startDate = draft.startDate
        endDate = draft.endDate
        notes = draft.notes
        loaded = true
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let draft = CalendarDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: startDate,
            endDate: max(endDate, startDate),
            notes: notes)
        Task {
            do {
                try await CalendarWriteAction(draft: draft).prepare().confirm()
                ToastCenter.shared.show(FCTToast(
                    title: "Added to Calendar", message: draft.title,
                    systemImage: "calendar.badge.checkmark", style: .success))
                onConfirmed?()
                dismiss()
            } catch {
                saving = false
                ToastCenter.shared.show(FCTToast(
                    title: "Couldn't add to Calendar",
                    message: EcosystemActionFeedback.message(for: error),
                    systemImage: "calendar.badge.exclamationmark", style: .error))
            }
        }
    }
}

/// **Draft-then-confirm — Reminders.** The action-item counterpart: reviews an extracted
/// `TranscriptActionItem`, optionally with a resolved due date, and commits through
/// `ReminderWriteAction` (minimal reminders scope) only on confirmation.
struct ReminderDraftConfirmView: View {
    let actionItemID: UUID
    /// Fires after a successful write, before this sheet dismisses (see `CalendarDraftConfirmView`).
    var onConfirmed: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var loaded = false
    @State private var saving = false
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                if loaded {
                    Section("Reminder") {
                        TextField("Title", text: $title)
                            .accessibilityIdentifier("reminderDraft.title")
                        Toggle("Due date", isOn: $hasDueDate)
                        if hasDueDate {
                            DatePicker("Due", selection: $dueDate)
                        }
                    }
                    if !notes.isEmpty {
                        Section("Notes") {
                            Text(notes).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button { save() } label: {
                            Label("Add Reminder", systemImage: "checklist")
                        }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("reminderDraft.add")
                    } footer: {
                        Text("Nothing is added until you tap Add.")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Add Reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        // A confirm failure surfaces an error toast while THIS sheet stays presented; the shared
        // overlay lives on the app root (occluded by the sheet), so install one on the sheet too.
        .withToast()
        #if os(macOS)
        .frame(width: DesignMetrics.macSheetSize.width, height: DesignMetrics.macSheetSize.height)
        #endif
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        let id = actionItemID
        var descriptor = FetchDescriptor<TranscriptActionItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { dismiss(); return }
        let draft = EventDraftMapper.reminderDraft(for: item, sessionTitle: item.session?.title ?? "")
        title = draft.title
        notes = draft.notes
        if let due = draft.dueDate {
            hasDueDate = true
            dueDate = due
        }
        loaded = true
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let draft = ReminderDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            dueDate: hasDueDate ? dueDate : nil)
        Task {
            do {
                try await ReminderWriteAction(draft: draft).prepare().confirm()
                ToastCenter.shared.show(FCTToast(
                    title: "Added Reminder", message: draft.title,
                    systemImage: "checklist.checked", style: .success))
                onConfirmed?()
                dismiss()
            } catch {
                saving = false
                ToastCenter.shared.show(FCTToast(
                    title: "Couldn't add Reminder",
                    message: EcosystemActionFeedback.message(for: error),
                    systemImage: "exclamationmark.triangle", style: .error))
            }
        }
    }
}

/// Maps a write error to a short, human toast message — the one place both confirm views phrase a
/// failure, so the wording stays consistent.
enum EcosystemActionFeedback {
    static func message(for error: Error) -> String {
        (error as? EventKitWriteError)?.errorDescription ?? "Please try again."
    }
}
