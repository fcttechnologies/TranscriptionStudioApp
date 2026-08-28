import SwiftUI
import SwiftData
import AppIntents

/// A saved session's transcript, presented as a sheet from the feed (and expanded from the
/// mini-player during playback). The reading surface: an identity header (kind chip, title,
/// date · duration), then the transcript — flat paragraphs for a single voice, grouped speaker
/// blocks for several (`TranscriptLayoutMode`) — with the Apple-Music karaoke treatment during
/// playback: the playing line lit, the rest receded, auto-scroll keeping it centered, any line
/// tappable to seek. A glass transport bar (±15s, scrubber, speed) floats in the bottom
/// safe-area when the session's audio was archived. Closing the sheet mid-play hands the audio
/// to the mini-player; exact per-segment confidence numbers live in the Inspector's ASR table.
struct SessionDetailView: View {
    let session: TranscriptSession

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playingLineID: String?
    @State private var hasAudio = false
    @State private var exportFormat: TranscriptExport.Format?
    @State private var showingIntelligence = false
    @State private var activeSuggestion: ActionSuggestion?
    @State private var isRenaming = false
    @State private var draftTitle = ""
    /// The last moment the reader scrolled by hand — auto-follow yields until it passes.
    @State private var lastUserScroll: Date?

    init(session: TranscriptSession) {
        self.session = session
    }

    private var turns: [TranscriptTurn] {
        TranscriptTurn.group(stored: session.segments ?? [])
    }

    var body: some View {
        let currentTurns = turns
        let layout = TranscriptLayoutMode.decide(turns: currentTurns)
        let currentLineStarts = currentTurns.flatMap { $0.lines }.map { (id: $0.id, start: $0.start) }
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignMetrics.turnSpacing) {
                        header
                        if session.isRemotePlaceholder {
                            RemoteWaitingView(isProcessing: session.isProcessingRemote)
                        } else {
                            // The assistant layer's delivery surface: extracted highlights as
                            // dismissible chips, each opening its Phase 3 confirm sheet.
                            SuggestedActionsRow(session: session) { activeSuggestion = $0 }
                            ForEach(currentTurns) { turn in
                                TranscriptTurnView(turn: turn,
                                                   playingLineID: playingLineID,
                                                   onTapLine: hasAudio ? { app.playback.play(from: $0.start) } : nil,
                                                   showsSpeaker: layout == .grouped,
                                                   karaoke: hasAudio,
                                                   confidenceHighlighting: app.settings.showConfidence)
                            }
                        }
                    }
                    .padding(DesignMetrics.spacingL)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase == .interacting { lastUserScroll = .now }
                }
                .onChange(of: playingLineID) { _, id in
                    followPlayhead(id, proxy: proxy)
                }
            }
            .background(.background)
            .safeAreaBar(edge: .bottom) {
                if hasAudio {
                    PlaybackBar(playback: app.playback)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button("Intelligence", systemImage: "sparkles") {
                        showingIntelligence = true
                        let entity = TranscriptSessionEntity(session)
                        Task { await TranscriptionIntentDonations.donateSummarizeTranscript(entity) }
                    }
                    .accessibilityIdentifier(A11yID.sessionIntelligence)
                }
                ToolbarItem {
                    Menu {
                        Button("Rename", systemImage: "pencil") { beginRenaming() }
                        Button("Copy Transcript", systemImage: "doc.on.doc") { copyTranscript() }
                        if !(session.segments ?? []).isEmpty {
                            Button("Speak Transcript", systemImage: "speaker.wave.2") {
                                app.startReadAloud(session: session)
                                let entity = TranscriptSessionEntity(session)
                                Task { await TranscriptionIntentDonations.donateSpeakTranscript(entity) }
                            }
                            .accessibilityIdentifier(A11yID.sessionSpeak)
                        }
                        Toggle(isOn: confidenceBinding) {
                            Label("Highlight Confidence", systemImage: "text.magnifyingglass")
                        }
                        .accessibilityIdentifier(A11yID.sessionConfidenceToggle)
                        Toggle(isOn: privacyBinding) {
                            Label("Lock with Face ID", systemImage: session.isPrivate ? "lock.fill" : "lock.open")
                        }
                        .accessibilityIdentifier(A11yID.sessionPrivacyToggle)
                        Menu {
                            ForEach(TranscriptExport.Format.allCases) { format in
                                Button(format.displayName) { exportFormat = format }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier(A11yID.sessionMore)
                }
                SheetCloseToolbar { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macDetailSheetSize.width,
               height: DesignMetrics.macDetailSheetSize.height)
        #endif
        .fileExporter(isPresented: exportBinding,
                      document: exportDocument,
                      contentType: exportFormat.map(TranscriptExportDocument.contentType(for:)) ?? .plainText,
                      defaultFilename: exportFileName) { result in
            if case .success = result, let format = exportFormat {
                let entity = TranscriptSessionEntity(session)
                Task { await TranscriptionIntentDonations.donateExportTranscript(entity, format: format) }
            }
            exportFormat = nil
        }
        .sheet(isPresented: $showingIntelligence) {
            SessionIntelligenceSheet(session: session)
        }
        // A tapped chip's Phase 3 draft-then-confirm surface, presented over this sheet so
        // confirming (or closing) lands the reader back on the transcript.
        .sheet(item: $activeSuggestion) { suggestion in
            suggestionSheet(for: suggestion)
        }
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Title", text: $draftTitle)
                .accessibilityIdentifier(A11yID.sessionRenameField)
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitRename() }
        }
        .modifier(PlayheadTracker(playback: app.playback, lineStarts: currentLineStarts,
                                  playingLineID: $playingLineID))
        // Onscreen awareness: let Siri / Apple Intelligence know which transcript is showing —
        // but never for a private session (it's withheld from the assistant surface).
        .modifier(OnscreenTranscript(session: session))
        // `.task` rather than `.onAppear`: a restored device fetches the recording on this
        // first read, and everything else on screen renders from synced records meanwhile.
        .task {
            hasAudio = await app.playback.prepare(session: session)
            guard PrivacyGate.isEligibleForAssistant(isPrivate: session.isPrivate) else { return }
            await TranscriptionIntentDonations.donateOpenTranscript(TranscriptSessionEntity(session))
        }
        // Engaged playback survives the sheet (the mini-player picks it up); audio that was
        // never played is put away.
        .onDisappear { app.playback.releaseIfIdle() }
    }

    // MARK: Header

    /// The session's identity: kind chip (the one eyebrow), the title (tap to rename), and the
    /// quiet date · duration line.
    private var header: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
            Label(SessionKindStyle.label(session.kind),
                  systemImage: SessionKindStyle.icon(session.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(SessionKindStyle.tint(session.kind))
                .padding(.horizontal, DesignMetrics.spacingS)
                .padding(.vertical, DesignMetrics.speakerChipVPadding)
                .background(SessionKindStyle.tint(session.kind).opacity(0.12), in: Capsule())
            Text(session.title.isEmpty ? "Untitled Session" : session.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { beginRenaming() }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Rename")
                .accessibilityIdentifier(A11yID.sessionTitle)
            HStack(spacing: DesignMetrics.spacingS) {
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                if session.duration > 0 {
                    Text("·")
                    Text(TimeFormat.clock(session.duration))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Opt-in recording location: one quiet chip, tapping opens Maps at the coordinate.
            if let locationChip = LocationChipPolicy.chip(for: session) {
                LocationChipView(chip: locationChip)
                    .padding(.top, DesignMetrics.spacingXS)
            }
        }
        .padding(.bottom, DesignMetrics.spacingS)
    }

    // MARK: Suggested actions

    /// The Phase 3 confirm surface a tapped chip opens — reused as-is, presented locally so the
    /// reader stays in the transcript. A confirmed write also retires its chip (served, not
    /// re-suggested); closing without confirming leaves the chip standing.
    @ViewBuilder
    private func suggestionSheet(for suggestion: ActionSuggestion) -> some View {
        switch suggestion.kind {
        case .calendarEvent:
            CalendarDraftConfirmView(eventID: suggestion.itemID) { suggestionServed(suggestion) }
        case .reminder:
            ReminderDraftConfirmView(actionItemID: suggestion.itemID) { suggestionServed(suggestion) }
        case .contact:
            #if os(iOS)
            SpeakerAssignmentSheet(sessionID: session.id)
            #else
            // Contact suggestions are never derived on macOS (no contact-picker surface).
            EmptyView()
            #endif
        }
    }

    private func suggestionServed(_ suggestion: ActionSuggestion) {
        withAnimation(reduceMotion ? nil : DesignMetrics.snappySpring) {
            ActionSuggestions.dismiss(suggestion.id, on: session, in: modelContext)
        }
    }

    // MARK: Karaoke auto-follow

    /// Keep the playing line centered — unless the reader recently took the scroll for
    /// themselves, in which case the follow yields and rejoins on a later line change.
    private func followPlayhead(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, app.playback.isPlaying else { return }
        if let lastUserScroll,
           Date.now.timeIntervalSince(lastUserScroll) < DesignMetrics.karaokeFollowResumeDelay {
            return
        }
        withAnimation(reduceMotion ? nil : DesignMetrics.liveFollowSpring) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: Export

    private var exportBinding: Binding<Bool> {
        Binding(get: { exportFormat != nil }, set: { if !$0 { exportFormat = nil } })
    }

    /// Persisted verbatim/confidence display toggle (see `AppSettings.showConfidence`).
    private var confidenceBinding: Binding<Bool> {
        Binding(get: { app.settings.showConfidence },
                set: { app.settings.showConfidence = $0 })
    }

    /// Per-session privacy lock. Flipping it persists the flag and re-syncs the assistant index
    /// (`index(_:)` self-guards — it removes a now-private session, re-adds a now-public one). No
    /// extra auth to toggle: the reader has already cleared the lock to be viewing this at all.
    private var privacyBinding: Binding<Bool> {
        Binding(get: { session.isPrivate },
                set: { newValue in
                    session.isPrivate = newValue
                    try? modelContext.save()
                    TranscriptSpotlightIndex.index(session)
                })
    }

    private var exportDocument: TranscriptExportDocument? {
        guard let exportFormat else { return nil }
        let data = TranscriptExport.renderData(TranscriptExport.items(from: session),
                                               as: exportFormat, title: session.title)
        return TranscriptExportDocument(data: data, format: exportFormat)
    }

    private var exportFileName: String {
        let base = session.title.isEmpty ? "Transcript" : session.title
        return "\(base).\(exportFormat?.fileExtension ?? "txt")"
    }

    // MARK: Rename

    private func beginRenaming() {
        draftTitle = session.title
        isRenaming = true
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        try? modelContext.save()
        TranscriptSpotlightIndex.index(session)
        let entity = TranscriptSessionEntity(session)
        Task { await TranscriptionIntentDonations.donateRenameTranscript(entity, newTitle: trimmed) }
    }

    private func copyTranscript() {
        let currentTurns = turns
        // Mirror the layout: a single voice copies as clean paragraphs, several keep their
        // speaker prefixes.
        let text: String
        switch TranscriptLayoutMode.decide(turns: currentTurns) {
        case .flat:
            text = currentTurns.flatMap(\.lines).map(\.text).joined(separator: "\n")
        case .grouped:
            text = currentTurns.map { turn in
                "\(turn.speaker.displayName): " + turn.lines.map(\.text).joined(separator: " ")
            }.joined(separator: "\n")
        }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Announces the shown transcript as the onscreen relevant entity for Siri / Apple
/// Intelligence — unless it's a private session, which is withheld from the assistant surface
/// entirely (`PrivacyGate.isEligibleForAssistant`). Two cues carry the same identity: the
/// view-level `appEntityIdentifier(_:)` annotation, and the advertised viewing activity whose
/// `NSUserActivity.appEntityIdentifier` matches (`SessionActivity`) — so "summarize this"
/// resolves to the visible session with zero parameters.
private struct OnscreenTranscript: ViewModifier {
    let session: TranscriptSession

    func body(content: Content) -> some View {
        if PrivacyGate.isEligibleForAssistant(isPrivate: session.isPrivate) {
            content
                .appEntityIdentifier(EntityIdentifier(for: TranscriptSessionEntity.self,
                                                      identifier: session.id.uuidString))
                .userActivity(SessionActivity.viewingType) { activity in
                    SessionActivity.configureViewing(activity,
                                                     sessionID: session.id,
                                                     title: session.title)
                }
        } else {
            content
        }
    }
}

/// Reads the playhead in isolation and maps it to the currently-playing line id, so the
/// per-tick playback update doesn't re-run the whole transcript body — only this modifier.
/// The mapping itself is `PlayheadMapper` (pure, unit-tested).
private struct PlayheadTracker: ViewModifier {
    let playback: PlaybackController
    let lineStarts: [(id: String, start: TimeInterval)]
    @Binding var playingLineID: String?

    func body(content: Content) -> some View {
        content.onChange(of: playback.currentTime) { _, time in
            let id = PlayheadMapper.lineID(at: time, lineStarts: lineStarts)
            if id != playingLineID { playingLineID = playback.isPlaying ? id : nil }
        }
    }
}

/// The transport, floating in the bottom safe-area on the shell's glass: the scrub row
/// (elapsed — slider — remaining), then speed · ±15s around the central play/pause.
private struct PlaybackBar: View {
    let playback: PlaybackController

    private var seekBinding: Binding<Double> {
        Binding(get: { playback.currentTime },
                set: { playback.seek(to: $0) })
    }

    var body: some View {
        VStack(spacing: DesignMetrics.spacingS) {
            HStack(spacing: DesignMetrics.spacingM) {
                Text(TimeFormat.clock(playback.currentTime))
                    .contentTransition(.numericText())
                Slider(value: seekBinding, in: 0...max(playback.duration, 0.1))
                    .accessibilityIdentifier(A11yID.sessionScrubber)
                Text("−" + TimeFormat.clock(max(playback.duration - playback.currentTime, 0)))
                    .contentTransition(.numericText())
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: DesignMetrics.spacingL) {
                speedControl
                Spacer(minLength: 0)
                CircleIconButton(systemImage: "gobackward.15",
                                 accessibilityLabel: "Back 15 seconds") {
                    playback.skip(by: -15)
                }
                playPauseButton
                CircleIconButton(systemImage: "goforward.15",
                                 accessibilityLabel: "Forward 15 seconds") {
                    playback.skip(by: 15)
                }
                Spacer(minLength: 0)
                // Optical balance for the leading speed control — same footprint, invisible.
                speedControl.hidden()
            }
        }
        .padding(DesignMetrics.spacingL)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DesignMetrics.cornerXL,
                                                    style: .continuous))
        .padding(.horizontal, DesignMetrics.spacingL)
        .frame(maxWidth: DesignMetrics.feedMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlayPause()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: DesignMetrics.playControlSize,
                       height: DesignMetrics.playControlSize)
                .background(.tint.opacity(0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier(A11yID.sessionPlayPause)
    }

    /// The playback-speed menu — a quiet monospaced "1×" that opens the rate picker.
    private var speedControl: some View {
        Menu {
            Picker("Playback Speed", selection: rateBinding) {
                ForEach(PlaybackController.playbackRates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
        } label: {
            Text(Self.rateLabel(playback.playbackRate))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 32)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed, \(Self.rateLabel(playback.playbackRate))")
        .accessibilityIdentifier(A11yID.sessionSpeed)
    }

    private var rateBinding: Binding<Float> {
        Binding(get: { playback.playbackRate },
                set: { playback.setPlaybackRate($0) })
    }

    static func rateLabel(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
