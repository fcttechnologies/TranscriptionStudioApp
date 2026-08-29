#if os(iOS)
import SwiftUI
import SwiftData
import Contacts
import ContactsUI

/// **Speaker → contact mapping (functional entry point).** Lists a session's diarized speakers and
/// lets the user bind each to a real contact through the system contact picker — which runs
/// out-of-process and needs *no* Contacts permission. A bound name is denormalized onto the session
/// (so labels + the Spotlight index need no re-fetch) and makes "what did they say" searchable by
/// name. A plain review list, reached from the shell's sheet routing and from the detail view's
/// "Save Contact" suggestion chips.
struct SpeakerAssignmentSheet: View {
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var slots: [Int] = []
    @State private var names: [Int: String] = [:]
    @State private var mentions: [ResolvedMention] = []
    @State private var picking: SlotBox?

    /// `Identifiable` wrapper so a slot can drive `.sheet(item:)`.
    private struct SlotBox: Identifiable { let id: Int }

    var body: some View {
        NavigationStack {
            Form {
                if slots.isEmpty {
                    ContentUnavailableView("No speakers to name", systemImage: "person.2",
                        description: Text("This transcript has no diarized speakers yet."))
                } else {
                    Section {
                        ForEach(slots, id: \.self) { slot in
                            row(for: slot)
                        }
                    } footer: {
                        Text("Naming a speaker makes “what did they say” searchable by name. Choosing a contact never grants access to your contacts.")
                    }
                }
                if !mentions.isEmpty {
                    Section("Mentioned in this transcript") {
                        ForEach(mentions, id: \.name) { mention in
                            HStack {
                                Text(mention.name)
                                Spacer()
                                if let contact = mention.contact {
                                    Label(contact.displayName, systemImage: "checkmark.circle.fill")
                                        .labelStyle(.titleAndIcon)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not in contacts").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Name speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .sheet(item: $picking) { box in
            ContactPickerView(
                onSelect: { assign(slot: box.id, contact: $0) },
                onCancel: { picking = nil })
            .ignoresSafeArea()
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func row(for slot: Int) -> some View {
        HStack {
            Label(SpeakerLabels.name(forSlot: slot), systemImage: "person.crop.circle")
            Spacer()
            if let name = names[slot] {
                Text(name).foregroundStyle(.secondary)
                Button("Clear", role: .destructive) { clear(slot) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(A11yID.speakerClear)
            } else {
                Button("Choose contact") { picking = SlotBox(id: slot) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(A11yID.speakerChooseContact)
            }
        }
    }

    private func session() -> TranscriptSession? {
        let id = sessionID
        var descriptor = FetchDescriptor<TranscriptSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func load() {
        guard let session = session() else { dismiss(); return }
        slots = SpeakerLabels.assignableSlots(in: session)
        names = SpeakerAssignmentStore.nameBySlot(for: session)
        resolveMentions(for: session)
    }

    /// Surface which extracted mentions are already in the user's contacts — only when read access is
    /// *already* granted, so opening this sheet never triggers a contacts-permission prompt.
    private func resolveMentions(for session: TranscriptSession) {
        let resolver = MentionResolver()
        guard resolver.canResolve else { return }
        let peopleNames = (session.people ?? []).map(\.name)
        guard !peopleNames.isEmpty else { return }
        Task {
            mentions = await resolver.resolve(names: peopleNames)
        }
    }

    private func assign(slot: Int, contact: SelectedContact) {
        picking = nil
        guard let session = session() else { return }
        SpeakerAssignmentStore.assign(slot: slot, contactIdentifier: contact.identifier,
                                      displayName: contact.displayName, to: session, in: modelContext)
        names = SpeakerAssignmentStore.nameBySlot(for: session)
    }

    private func clear(_ slot: Int) {
        guard let session = session() else { return }
        SpeakerAssignmentStore.clear(slot: slot, from: session, in: modelContext)
        names = SpeakerAssignmentStore.nameBySlot(for: session)
    }
}

/// A contact chosen from the system picker, reduced to what a binding needs.
struct SelectedContact: Sendable {
    let identifier: String
    let displayName: String
}

/// SwiftUI bridge to `CNContactPickerViewController` — the system picker needs no Contacts
/// permission (it runs out of process and hands back only the contact the user taps).
private struct ContactPickerView: UIViewControllerRepresentable {
    let onSelect: (SelectedContact) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: (SelectedContact) -> Void
        let onCancel: () -> Void

        init(onSelect: @escaping (SelectedContact) -> Void, onCancel: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let formatter = CNContactFormatter()
            formatter.style = .fullName
            let name = formatter.string(from: contact)
                ?? [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            onSelect(SelectedContact(identifier: contact.identifier, displayName: name))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }
    }
}
#endif
