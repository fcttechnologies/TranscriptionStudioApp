import SwiftUI
import SwiftData

/// The Library: saved sessions grouped by day, kind-badged, searchable over their full text,
/// deletable with confirmation. Tapping a session opens its transcript with playback.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptSession.createdAt, order: .reverse) private var sessions: [TranscriptSession]

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var path: [TranscriptSession] = []
    @State private var pendingDelete: TranscriptSession?
    @State private var showingSettings = false

    public init() {}

    public var body: some View {
        NavigationStack(path: $path) {
            LibraryList(sessions: sessions, searchText: debouncedSearchText, pendingDelete: $pendingDelete)
                .navigationTitle("Library")
                .navigationDestination(for: TranscriptSession.self) { session in
                    SessionDetailView(session: session)
                }
                #if os(iOS)
                // iOS has no Settings scene; reach settings from the Library nav bar.
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                            .accessibilityIdentifier("library.settings")
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingSettings = false }
                                }
                            }
                    }
                }
                #endif
        }
        .searchable(text: $searchText, prompt: "Search transcripts")
        .task(id: searchText) {
            // Debounce the full-text scan: only re-filter once typing pauses, instead of
            // re-scanning every session's fullText on each keystroke.
            do {
                try await Task.sleep(for: .milliseconds(200))
                debouncedSearchText = searchText
            } catch {}
        }
        .confirmationDialog("Delete this session?", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { delete(pendingDelete) } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "“\($0.title)” and its transcript will be removed." } ?? "")
        }
        .onChange(of: app.selectedSessionID) { _, id in openSelected(id) }
        .onAppear { openSelected(app.selectedSessionID) }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func delete(_ session: TranscriptSession) {
        if let name = session.audioFileName, let url = AudioFileIO.url(forFileName: name) {
            try? FileManager.default.removeItem(at: url)
        }
        let deletedID = session.id
        modelContext.delete(session)
        try? modelContext.save()
        TranscriptSpotlightIndex.deindex(id: deletedID)
        pendingDelete = nil
    }

    private func openSelected(_ id: UUID?) {
        guard let id, let session = sessions.first(where: { $0.id == id }) else { return }
        if path.last?.id != id { path = [session] }
        app.selectedSessionID = nil
    }
}

/// The session list content, as its own invalidation boundary: its only inputs are `sessions`
/// and the (debounced) `searchText`, so a sheet toggle or a pending-delete change elsewhere in
/// `LibraryView` doesn't re-walk or re-filter the library.
private struct LibraryList: View {
    let sessions: [TranscriptSession]
    let searchText: String
    @Binding var pendingDelete: TranscriptSession?

    var body: some View {
        let filtered = filtered
        if sessions.isEmpty {
            ContentUnavailableView {
                Label("No sessions yet", systemImage: "books.vertical")
            } description: {
                Text("Transcribe a file or record a session and it lands here.")
            }
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(sections(for: filtered), id: \.day) { section in
                    Section(DayFormat.header(section.day)) {
                        ForEach(section.sessions) { session in
                            NavigationLink(value: session) {
                                SessionRow(session: session)
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = session
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var filtered: [TranscriptSession] {
        guard !searchText.isEmpty else { return sessions }
        let needle = searchText.lowercased()
        return sessions.filter {
            $0.title.lowercased().contains(needle) || $0.fullText.lowercased().contains(needle)
        }
    }

    /// Sessions bucketed by calendar day, newest day first.
    private func sections(for filtered: [TranscriptSession]) -> [(day: Date, sessions: [TranscriptSession])] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.sorted { $0.key > $1.key }.map { (day: $0.key, sessions: $0.value) }
    }
}

/// One session row: kind badge, title, and a metadata line (time · duration · speaker count).
struct SessionRow: View {
    let session: TranscriptSession

    private var speakerCount: Int {
        Set((session.segments ?? []).map(\.speakerSlot)).count
    }

    var body: some View {
        let metadata = metadata
        HStack(spacing: DesignMetrics.spacingM) {
            Image(systemName: SessionKindStyle.icon(session.kind))
                .font(.title3)
                .foregroundStyle(SessionKindStyle.tint(session.kind))
                .frame(width: 34, height: 34)
                .background(SessionKindStyle.tint(session.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.body.weight(.medium)).lineLimit(1)
                Text(metadata).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(metadata)")
    }

    private var metadata: String {
        var parts = [session.createdAt.formatted(date: .omitted, time: .shortened)]
        if session.duration > 0 { parts.append(TimeFormat.clock(session.duration)) }
        if speakerCount > 1 { parts.append("\(speakerCount) speakers") }
        return parts.joined(separator: " · ")
    }
}

/// Kind → icon + tint, shared by the row and the detail header.
enum SessionKindStyle {
    static func icon(_ kind: SessionKind) -> String {
        switch kind {
        case .urlTranscription: "link"
        case .fileTranscription: "waveform"
        case .roomRecording: "mic"
        case .meetingRecording: "person.2.wave.2"
        }
    }
    static func tint(_ kind: SessionKind) -> Color {
        switch kind {
        case .urlTranscription: .blue
        case .fileTranscription: .indigo
        case .roomRecording: .green
        case .meetingRecording: .orange
        }
    }
    static func label(_ kind: SessionKind) -> String {
        switch kind {
        case .urlTranscription: "Link"
        case .fileTranscription: "File"
        case .roomRecording: "Room recording"
        case .meetingRecording: "Meeting"
        }
    }
}

/// Day-section header formatting (Today / Yesterday / date).
enum DayFormat {
    static func header(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}
