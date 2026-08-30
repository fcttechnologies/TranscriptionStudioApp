import SwiftUI
import SwiftData

/// The sessions feed — the app's one view. Saved sessions as quiet cards grouped by day,
/// newest first, filtered live by the shell's search text. Swipe-to-delete (with confirm)
/// and a delete context menu ride on each card; tapping one opens its transcript sheet.
///
/// The day grouping is native SwiftData sectioning (`@Query(sectionBy:)`, SDK 27) keyed on
/// ``TranscriptSession/daySectionKey``; `@Query` also keeps the feed live for *local* writes.
/// Cross-device freshness — which a bare `@Query` misses — is driven by the host
/// re-identifying this view on a remote import (see `StudioHomeView`/`SessionStoreObserver`).
struct SessionFeed: View {
    @Query(sort: \TranscriptSession.createdAt, order: .reverse, animation: .default,
           sectionBy: \.daySectionKey)
    private var sessions: SectionedResults<TranscriptSession, String>

    let searchText: String
    @Binding var pendingDelete: TranscriptSession?
    let onOpen: (TranscriptSession) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The native day sections, newest first, with each section's sessions filtered by the live
    /// search text; sections no session matches are dropped. `@Query` provides the day buckets;
    /// the in-memory ``SessionFilter/filter(_:query:)`` keeps search identical to before.
    private var visibleSections: [(key: String, sessions: [TranscriptSession])] {
        sessions.compactMap { section in
            let matches = SessionFilter.filter(Array(section), query: searchText)
            return matches.isEmpty ? nil : (key: section.id, sessions: matches)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignMetrics.feedSectionSpacing) {
                ActiveWorkSection()

                if sessions.isEmpty {
                    emptyFeed
                } else if visibleSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, DesignMetrics.spacingXXL)
                } else {
                    ForEach(visibleSections, id: \.key) { section in
                        VStack(alignment: .leading, spacing: DesignMetrics.feedRowSpacing) {
                            SectionLabel(LocalizedStringKey(DayFormat.header(sectionDay(section.sessions))))
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.horizontal) { width, _ in
                DesignMetrics.feedWidth(forContainer: width)
            }
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : DesignMetrics.standardSpring,
                       value: visibleSections.map { $0.sessions.map(\.id) })
        }
        .swipeActionsContainer()
        .contentMargins(.vertical, DesignMetrics.spacingM, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .background(.feedCanvas)
        .accessibilityIdentifier(A11yID.homeFeed)
    }

    /// The calendar day a section represents, taken from its (newest-first) sessions — used only
    /// for the human header ("Today"/"Yesterday"/date); the grouping key itself is `section.key`.
    private func sectionDay(_ sessions: [TranscriptSession]) -> Date {
        Calendar.current.startOfDay(for: sessions.first?.createdAt ?? .now)
    }

    private var emptyFeed: some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "waveform")
        } description: {
            Text("Record, or import audio with the + button — everything lands here.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignMetrics.spacingXXL)
        // Reachable by an agent because the claim it makes is one worth asserting: this surface is
        // only ever built after the front door's restore has landed, so "no sessions yet" is a
        // fact about the account rather than about a pull still in flight.
        .accessibilityIdentifier(A11yID.feedEmpty)
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
        .accessibilityIdentifier(A11yID.homeSession(session.id))
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
            if session.isPrivate {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Locked")
            }
            if session.isProcessingRemote {
                ProgressView().controlSize(.small)
            } else if session.isAwaitingRemote {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            } else if session.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.isPrivate ? "locked, " : "")\(metadata)")
    }

    private var metadata: String {
        // A companion link waiting on (or transcribing on) the Mac reads its status, not stats.
        if session.isAwaitingRemote { return "Waiting for your Mac…" }
        if session.isProcessingRemote { return "Transcribing on your Mac…" }
        var parts = [session.createdAt.formatted(date: .omitted, time: .shortened)]
        if session.duration > 0 { parts.append(TimeFormat.clock(session.duration)) }
        if speakerCount > 1 { parts.append("\(speakerCount) speakers") }
        return parts.joined(separator: " · ")
    }
}

/// Pure feed shaping — the live search filter, kept view-free so it's directly tested. (Day
/// bucketing is now native `@Query` sectioning; see ``SessionFeed`` / `TranscriptSession.daySectionKey`.)
enum SessionFilter {
    /// Case-insensitive match over title + full text; an empty query passes everything through.
    static func filter(_ sessions: [TranscriptSession], query: String) -> [TranscriptSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(needle) || $0.fullText.lowercased().contains(needle)
        }
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
