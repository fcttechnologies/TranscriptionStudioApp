import SwiftUI
import SwiftData

/// The sessions feed — the app's one view. Saved sessions as quiet cards grouped by day,
/// newest first, filtered live by the shell's search text. Swipe-to-delete (with confirm)
/// and a delete context menu ride on each card; tapping one opens its transcript sheet.
struct SessionFeed: View {
    let sessions: [TranscriptSession]
    let searchText: String
    @Binding var pendingDelete: TranscriptSession?
    let onOpen: (TranscriptSession) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let filtered = SessionFilter.filter(sessions, query: searchText)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignMetrics.feedSectionSpacing) {
                ActiveWorkSection()

                if sessions.isEmpty {
                    emptyFeed
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, DesignMetrics.spacingXXL)
                } else {
                    ForEach(SessionFilter.daySections(filtered), id: \.day) { section in
                        VStack(alignment: .leading, spacing: DesignMetrics.feedRowSpacing) {
                            SectionLabel(LocalizedStringKey(DayFormat.header(section.day)))
                                .padding(.leading, DesignMetrics.spacingXS)
                            ForEach(section.sessions) { session in
                                SessionCard(session: session) { onOpen(session) }
                                    .contextMenu {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            pendingDelete = session
                                        }
                                    }
                                    .swipeActions {
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            pendingDelete = session
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DesignMetrics.spacingL)
            .frame(maxWidth: DesignMetrics.feedMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : DesignMetrics.standardSpring,
                       value: filtered.map(\.id))
        }
        .swipeActionsContainer()
        .contentMargins(.vertical, DesignMetrics.spacingM, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .background(.feedCanvas)
        .accessibilityIdentifier("home.feed")
    }

    private var emptyFeed: some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "waveform")
        } description: {
            Text("Record, or import audio with the + button — everything lands here.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignMetrics.spacingXXL)
    }
}

/// One saved session as a card: kind-tinted icon tile, title, metadata line. The whole card
/// is the tap target for opening the transcript sheet.
struct SessionCard: View {
    let session: TranscriptSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SessionRow(session: session)
                .padding(.horizontal, DesignMetrics.spacingL)
                .padding(.vertical, DesignMetrics.spacingM)
                .cardStyle(cornerRadius: DesignMetrics.cornerL)
                .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.cornerL, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("home.session.\(session.id.uuidString)")
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
                .background(SessionKindStyle.tint(session.kind).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.body.weight(.medium)).lineLimit(1)
                Text(metadata).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
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

/// Pure feed shaping — filtering and day bucketing, kept view-free so it's directly tested.
enum SessionFilter {
    /// Case-insensitive match over title + full text; an empty query passes everything through.
    static func filter(_ sessions: [TranscriptSession], query: String) -> [TranscriptSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(needle) || $0.fullText.lowercased().contains(needle)
        }
    }

    /// Sessions bucketed by calendar day, newest day first (input order kept within a day).
    static func daySections(_ sessions: [TranscriptSession])
        -> [(day: Date, sessions: [TranscriptSession])] {
        let groups = Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.sorted { $0.key > $1.key }.map { (day: $0.key, sessions: $0.value) }
    }
}

/// Kind → icon + tint, shared by the row, the detail header, and the mini-player tile.
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
