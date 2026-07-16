import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import FCTCloudKit
#if os(iOS)
import PhotosUI
#endif

/// The app — one view. The sessions feed is home; everything else floats over it or
/// presents from it: Inspector (top-left) and Settings (top-right) as sheets, Search in the
/// bottom bar, the "+" menu (bottom-right) carrying what used to be the Transcribe and
/// Record tabs, the mini-player for live audio, and toasts for anything preparing or
/// downloading. Both platforms embed this; `Capabilities` gates the Mac-only entry points.
public struct StudioHomeView: View {
    /// What the hosting platform can do — the Mac shell turns this on. (URL ingest is no longer a
    /// capability flag: both platforms show Insert Link, and `AppModel.submitLink` routes to local
    /// transcription or a remote queue based on whether the device has the URL downloader.)
    public struct Capabilities: Sendable {
        public let meetingCapture: Bool
        public init(meetingCapture: Bool = false) {
            self.meetingCapture = meetingCapture
        }
    }

    let capabilities: Capabilities

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    // Optional so previews/tests that host this view without the app-root injection still resolve.
    @Environment(CloudKitSyncMonitor.self) private var cloudKitSync: CloudKitSyncMonitor?
    @Environment(LibraryBootstrap.self) private var bootstrap: LibraryBootstrap?
    // Explicit fetch rather than @Query: @Query re-evaluates for local writes but not for a
    // remote CloudKit import merged on the container's background context, which would leave the
    // feed stale until relaunch. `storeObserver` bumps `changeToken` on both local saves and
    // remote imports, and the feed re-fetches off it (see SessionStoreObserver).
    @State private var sessions: [TranscriptSession] = []
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

    public init(capabilities: Capabilities = Capabilities()) {
        self.capabilities = capabilities
    }

    public var body: some View {
        @Bindable var app = app
        NavigationStack {
            SessionFeed(sessions: sessions,
                        searchText: debouncedSearchText,
                        pendingDelete: $pendingDelete,
                        onOpen: { app.openSession(id: $0.id) })
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
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { session in
            Text("“\(session.title)” and its transcript will be removed.")
        }
        .sheet(item: $app.activeSheet) { sheet in
            sheetContent(sheet)
                .environment(app)
        }
        .toastOverlay()
        .overlay { bootstrapOverlay }
        .task {
            if storeObserver == nil {
                storeObserver = SessionStoreObserver(container: modelContext.container)
            }
            refreshSessions()
            bootstrap?.beginIfNeeded()
        }
        // Re-fetch when a local save or a remote CloudKit import lands. Replacing the `sessions`
        // array (stable session identity) lets the feed's ForEach diff in place — scroll position
        // and the day sections are preserved, no jarring rebuild.
        .onChange(of: storeObserver?.changeToken) { _, _ in refreshSessions() }
        .onChange(of: sessions.isEmpty) { _, isEmpty in
            // The library arrived (or was never empty) — reveal the feed, don't sit behind the gate.
            if !isEmpty { bootstrap?.markReady() }
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
        Button("Ask your library", systemImage: "sparkles.magnifyingglass") {
            app.activeSheet = .askLibrary
        }
        .accessibilityIdentifier("toolbar.askLibrary")
    }

    /// A quiet CloudKit sync-status glyph (syncing/error; invisible when idle).
    private var syncIndicator: some View {
        SyncStatusIndicator(monitor: cloudKitSync)
    }

    private var inspectorButton: some View {
        Button("Inspector", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            app.activeSheet = .inspector
        }
        .keyboardShortcut("i", modifiers: .command)
        .accessibilityIdentifier("toolbar.inspectorToggle")
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            app.activeSheet = .settings
        }
        .accessibilityIdentifier("toolbar.settingsToggle")
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
            .accessibilityIdentifier("toolbar.stop")
        } else {
            Menu {
                Button("Start Recording", systemImage: "mic") {
                    app.requestRecording(mode: .room)
                }
                if capabilities.meetingCapture {
                    Button("Record Meeting", systemImage: "person.2.wave.2") {
                        app.requestRecording(mode: .meeting)
                    }
                }
                Divider()
                #if os(iOS)
                Button("Upload from Photos", systemImage: "photo.on.rectangle") {
                    photosPickerPresented = true
                }
                #endif
                Button("Choose a File…", systemImage: "folder") {
                    isImporting = true
                }
                // Both platforms: the Mac transcribes the link locally, iOS queues it for the Mac.
                Button("Insert Link…", systemImage: "link") {
                    app.activeSheet = .insertLink
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("toolbar.compose")
        }
    }

    /// First-launch "syncing your library…" state, shown over an empty feed while the initial
    /// CloudKit import is still landing — so a fresh install doesn't read as "you have nothing".
    @ViewBuilder
    private var bootstrapOverlay: some View {
        if bootstrap?.phase == .syncing, sessions.isEmpty {
            ContentUnavailableView {
                Label("Syncing your library…", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Getting your transcripts from iCloud.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.feedCanvas)
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
            if let session = sessions.first(where: { $0.id == id }) {
                SessionDetailView(session: session)
            } else {
                // The session vanished (deleted elsewhere) — nothing to show.
                Color.clear.onAppear { app.returnHome() }
            }
        }
    }

    // MARK: Feed data

    /// Fetch the feed newest-first from the view context. A fresh fetch reads the store's current
    /// state — including rows a CloudKit import merged in — which is what a bare `@Query` misses.
    private func refreshSessions() {
        let descriptor = FetchDescriptor<TranscriptSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        sessions = (try? modelContext.fetch(descriptor)) ?? []
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
        // Deleting the record drops its archived `audioData` with it — no file to clean up.
        let deletedID = session.id
        if app.playback.nowPlaying?.sessionID == deletedID { app.playback.unload() }
        modelContext.delete(session)
        try? modelContext.save()
        TranscriptSpotlightIndex.deindex(id: deletedID)
        // A finished job's row would otherwise linger after its session is gone; a
        // still-running job has no resultSessionID yet, so it's untouched.
        app.jobs.removeJobs(forSessionID: deletedID)
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
