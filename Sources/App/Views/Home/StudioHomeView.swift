import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import FCTComponentsUI
#if os(iOS)
import PhotosUI
#endif

/// The app — one view. The sessions feed is home; everything else floats over it or
/// presents from it: Inspector (top-left) and Settings (top-right) as sheets, Search in the
/// bottom bar, the "+" menu (bottom-right) carrying what used to be the Transcribe and
/// Record tabs, the mini-player for live audio, and toasts for anything preparing or
/// downloading. Both platforms embed this; `Capabilities` gates the Mac-only entry points.
struct StudioHomeView: View {
    /// What the hosting platform can do — the Mac shell turns this on. (URL ingest is no longer a
    /// capability flag: both platforms show Insert Link, and `AppModel.submitLink` routes to local
    /// transcription or a remote queue based on whether the device has the URL downloader.)
    struct Capabilities: Sendable {
        let meetingCapture: Bool
        init(meetingCapture: Bool = false) {
            self.meetingCapture = meetingCapture
        }
    }

    let capabilities: Capabilities

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    // Optional so previews/tests that host this view without the app-root injection still resolve.
    @Environment(TranscriptionSync.self) private var sync: TranscriptionSync?
    // The feed itself is a native `@Query(sectionBy:)` in `SessionFeed` (live for local writes).
    // `storeObserver` supplies the cross-device freshness a bare `@Query` misses: its
    // `remoteGeneration` re-identifies the feed on a change the sync applier landed.
    //
    // This view never reasons about an empty library meaning anything: it is constructed only
    // after the front door's restore stage has landed the account's first pull, so an empty feed
    // here is genuinely empty (`TranscriptionFrontDoor`).
    @State private var storeObserver: SessionStoreObserver?

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var pendingDelete: TranscriptSession?
    @State private var isImporting = false
    @State private var isDropTargeted = false
    #if os(iOS)
    @State private var photosPickerPresented = false
    @State private var photosSelection: PhotosPickerItem?
    #endif

    init(capabilities: Capabilities = Capabilities()) {
        self.capabilities = capabilities
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            SessionFeed(searchText: debouncedSearchText,
                        pendingDelete: $pendingDelete,
                        onOpen: { app.openSession(id: $0.id) })
                // Re-identify on an applied remote change (only) so the inner `@Query` re-fetches
                // the synced rows; local writes update it in place with no rebuild.
                .id(storeObserver?.remoteGeneration ?? 0)
                .navigationTitle("Sessions")
                .searchable(text: $searchText, prompt: "Search transcripts")
                .toolbar { homeToolbar }
                .safeAreaBar(edge: .bottom) { MiniPlayerBar() }
        }
        .task(id: searchText) {
            // Debounce the full-text scan: only re-filter once typing pauses, instead of
            // re-scanning every session's fullText on each keystroke.
            do {
                try await Task.sleep(for: .milliseconds(200))
                debouncedSearchText = searchText
                await TranscriptionIntentDonations.donateSearchTranscripts(query: searchText)
            } catch {}
        }
        // Item-bound dialog (SDK 27): presents while `pendingDelete` holds a value and hands
        // the session straight to `actions`/`message`, so both a card swipe and the context
        // menu confirm against the exact session that's pending, never a stale shared Bool.
        .confirmationDialog("Delete this session?", item: $pendingDelete, titleVisibility: .visible) { session in
            Button("Delete", role: .destructive) { delete(session) }
                .accessibilityIdentifier(A11yID.confirmDeleteSession)
            Button("Cancel", role: .cancel) { pendingDelete = nil }
                .accessibilityIdentifier(A11yID.confirmDeleteCancel)
        } message: { session in
            Text("“\(session.title)” and its transcript will be removed.")
        }
        .sheet(item: $app.activeSheet) { sheet in
            sheetContent(sheet)
                .environment(app)
        }
        .withToast()
        .task {
            if storeObserver == nil {
                storeObserver = SessionStoreObserver(container: modelContext.container)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { startFile(url) }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { DropHint() } }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: SupportedMediaExtensions.contentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { startFile(url) }
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $photosPickerPresented, selection: $photosSelection,
                      matching: .videos, photoLibrary: .shared())
        .onChange(of: photosSelection) { _, newValue in
            guard let newValue else { return }
            Task { await importPhotosVideo(newValue) }
        }
        #endif
        .onChange(of: app.enginePrewarmState) { old, new in
            ToastCenter.shared.handlePrewarm(from: old, to: new)
        }
        .onChange(of: app.recording.lastError) { _, error in
            guard let error else { return }
            ToastCenter.shared.show(.recordingFailed(error.message))
            app.recording.clearError()
        }
        .onChange(of: app.recording.phase) { old, new in
            // Donate only on a real preparing → recording transition (a successful start),
            // never on resume-from-pause (phase stays .recording) or a failed prepare.
            if case .recording = new, case .preparing = old {
                let mode = app.recording.mode
                Task { await TranscriptionIntentDonations.donateStartRecording(mode: mode) }
            }
        }
    }

    // MARK: Toolbar — the four controls

    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) { inspectorButton }
        ToolbarItem(placement: .topBarTrailing) { askButton }
        ToolbarItem(placement: .topBarTrailing) { syncIndicator }
        ToolbarItem(placement: .topBarTrailing) { settingsButton }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { composeControl }
        #else
        ToolbarItem(placement: .navigation) { inspectorButton }
        ToolbarItem { askButton }
        ToolbarItem { syncIndicator }
        ToolbarItem { settingsButton }
        ToolbarItem(placement: .primaryAction) { composeControl }
        #endif
    }

    /// Opens library-wide semantic Q&A (Flagship A).
    private var askButton: some View {
        Button("Ask your library", systemImage: "sparkle.magnifyingglass") {
            app.activeSheet = .askLibrary
        }
        .accessibilityIdentifier(A11yID.toolbarAskLibrary)
    }

    /// A quiet sync-status glyph (syncing/offline/needs-attention; invisible when idle).
    private var syncIndicator: some View {
        SyncStatusIndicator(sync: sync)
    }

    private var inspectorButton: some View {
        Button("Inspector", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            app.activeSheet = .inspector
        }
        .keyboardShortcut("i", modifiers: .command)
        .accessibilityIdentifier(A11yID.toolbarInspectorToggle)
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            app.activeSheet = .settings
        }
        .accessibilityIdentifier(A11yID.toolbarSettingsToggle)
    }

    /// The "+" menu — and, while a recording runs, the Stop button it becomes.
    @ViewBuilder
    private var composeControl: some View {
        if app.recording.isActive {
            Button {
                app.stopRecordingAndOpen()
            } label: {
                if app.recording.phase == .finishing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
            }
            .tint(.red)
            .disabled(app.recording.phase == .finishing)
            .accessibilityIdentifier(A11yID.toolbarStop)
        } else {
            Menu {
                Button("Start Recording", systemImage: "mic") {
                    app.requestRecording(mode: .room)
                }
                .accessibilityIdentifier(A11yID.composeStartRecording)
                if capabilities.meetingCapture {
                    Button("Record Meeting", systemImage: "person.2.wave.2") {
                        app.requestRecording(mode: .meeting)
                    }
                    .accessibilityIdentifier(A11yID.composeRecordMeeting)
                }
                Divider()
                #if os(iOS)
                Button("Upload from Photos", systemImage: "photo.on.rectangle") {
                    photosPickerPresented = true
                }
                .accessibilityIdentifier(A11yID.composeUploadFromPhotos)
                #endif
                Button("Choose a File…", systemImage: "folder") {
                    isImporting = true
                }
                .accessibilityIdentifier(A11yID.composeChooseFile)
                // Both platforms: the Mac transcribes the link locally, iOS queues it for the Mac.
                Button("Insert Link…", systemImage: "link") {
                    app.activeSheet = .insertLink
                }
                .accessibilityIdentifier(A11yID.composeInsertLink)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier(A11yID.toolbarCompose)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: StudioSheet) -> some View {
        switch sheet {
        case .settings:
            SettingsSheet()
        case .inspector:
            InspectorSheet()
        case .liveRecording:
            LiveRecordingSheet()
        case .insertLink:
            InsertLinkSheet()
        case .askLibrary:
            AskLibraryView()
        case .session(let id):
            if let session = fetchSession(id: id) {
                SessionDetailView(session: session)
            } else {
                // The session vanished (deleted elsewhere) — nothing to show.
                Color.clear.onAppear { app.returnHome() }
            }
        case .confirmCalendarEvent(let id):
            CalendarDraftConfirmView(eventID: id)
        case .confirmReminder(let id):
            ReminderDraftConfirmView(actionItemID: id)
        #if os(iOS)
        case .assignSpeakers(let id):
            SpeakerAssignmentSheet(sessionID: id)
        #endif
        }
    }

    // MARK: Feed data

    /// Resolve one session by id from the view context — for the open-transcript sheet.
    private func fetchSession(id: UUID) -> TranscriptSession? {
        var descriptor = FetchDescriptor<TranscriptSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: Ingest actions

    private func startFile(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        app.startTranscription(title: name.isEmpty ? "Audio file" : name, source: .file(url))
        Task { await TranscriptionIntentDonations.donateTranscribeFile(fileURL: url) }
    }

    #if os(iOS)
    @MainActor
    private func importPhotosVideo(_ item: PhotosPickerItem) async {
        photosSelection = nil
        do {
            guard let picked = try await item.loadTransferable(type: PickedPhotosVideo.self) else {
                ToastCenter.shared.show(.importFailed("Couldn't load that video."))
                return
            }
            app.startTranscription(title: picked.title, source: .file(picked.url))
        } catch {
            ToastCenter.shared.show(.importFailed(error.localizedDescription))
        }
    }
    #endif

    // MARK: Delete

    private func delete(_ session: TranscriptSession) {
        let entity = TranscriptSessionEntity(session)
        SessionDeletion.delete(session, in: modelContext, app: app)
        pendingDelete = nil
        Task { await TranscriptionIntentDonations.donateDeleteTranscript(entity) }
    }
}

/// The drag-and-drop affordance: a quiet full-surface hint while a file hovers.
private struct DropHint: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignMetrics.cornerXL, style: .continuous)
                .strokeBorder(Color.accentColor,
                              style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(DesignMetrics.spacingM)
            Label("Drop to transcribe", systemImage: "square.and.arrow.down.on.square")
                .font(.headline)
                .padding(.horizontal, DesignMetrics.spacingL)
                .padding(.vertical, DesignMetrics.spacingM)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Settings in the sheet shell both platforms share.
private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    SheetCloseToolbar { dismiss() }
                }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macSheetSize.width,
               height: DesignMetrics.macSheetSize.height)
        #endif
    }
}

/// The Inspector in the sheet shell — the same presentation on both platforms.
private struct InspectorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InspectorView()
                .navigationTitle("Inspector")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    SheetCloseToolbar { dismiss() }
                }
        }
        #if os(macOS)
        .frame(width: DesignMetrics.macSheetSize.width,
               height: DesignMetrics.macSheetSize.height)
        #endif
    }
}
