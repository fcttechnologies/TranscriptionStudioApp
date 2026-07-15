import SwiftUI
import SwiftData
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    @State private var app: AppModel

    init() {
        let model = AppModel.live(captureFactory: { mode, sessionID, recorder in
            // iOS records from the microphone in every mode (meeting capture is Mac-only and
            // the surface doesn't exist here).
            _ = mode
            return [.init(source: MicCaptureSource(track: .mixed, sessionID: sessionID, recorder: recorder),
                          tracks: [.mixed])]
        })
        // Register the live model so App Intents (Siri/Shortcuts) resolve it via @Dependency.
        TranscriptionAppIntents.registerDependencies(appModel: model)
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(app)
                .task {
                    TranscriptSpotlightIndex.reindexAll()
                    // Warm the speech model up front so the first job isn't blocked by the
                    // one-time model compile (see AppModel.prewarmDefaultEngine).
                    app.prewarmDefaultEngine()
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

/// The iOS shell: a tab per surface, iPhone-native (not a shrunk Mac). No URL ingest and no
/// meeting mode (both are Mac-only capabilities); the Inspector is a sheet rather than a
/// trailing column. Settings and the Inspector are both reached from every tab's nav bar
/// (there's no Mac-style Settings scene or sidebar-adjacent Inspector column on iOS).
struct IOSRootView: View {
    @Environment(AppModel.self) private var app
    @State private var showingSettings = false

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedSurface) {
            Tab(AppSurface.transcribe.title, systemImage: AppSurface.transcribe.systemImage,
                value: AppSurface.transcribe) {
                NavigationStack {
                    TranscribeView(showsURLField: false)
                        .toolbar { AppToolbar(app: app, showingSettings: $showingSettings) }
                }
            }
            Tab(AppSurface.record.title, systemImage: AppSurface.record.systemImage,
                value: AppSurface.record) {
                NavigationStack {
                    RecordView(availableModes: [.room])
                        .toolbar { AppToolbar(app: app, showingSettings: $showingSettings) }
                }
            }
            Tab(AppSurface.library.title, systemImage: AppSurface.library.systemImage,
                value: AppSurface.library) {
                LibraryView()
                    .toolbar { AppToolbar(app: app, showingSettings: $showingSettings) }
            }
        }
        .sheet(isPresented: $app.isInspectorPresented) {
            NavigationStack {
                InspectorView()
                    .navigationTitle("Inspector")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { app.isInspectorPresented = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
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
        .onChange(of: app.pendingSettingsRequest) { _, requested in
            guard requested else { return }
            showingSettings = true
            app.pendingSettingsRequest = false
        }
    }
}

/// The Settings + Inspector buttons shared by every iOS surface's navigation bar, so both
/// are reachable regardless of the active tab instead of only from Library.
private struct AppToolbar: ToolbarContent {
    let app: AppModel
    @Binding var showingSettings: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                .accessibilityIdentifier("toolbar.settingsToggle")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                app.isInspectorPresented = true
            } label: {
                Label("Inspector", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            .accessibilityIdentifier("toolbar.inspectorToggle")
        }
    }
}
