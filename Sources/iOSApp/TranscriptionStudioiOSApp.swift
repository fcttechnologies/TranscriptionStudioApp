import SwiftUI
import SwiftData
import TranscriptionKit

@main
struct TranscriptionStudioiOSApp: App {
    @State private var app = AppModel.live()

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(app)
                .task { app.seedSampleSessionIfNeeded() }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

/// The iOS shell: a tab per surface, iPhone-native (not a shrunk Mac). No URL ingest and no
/// meeting mode (both are Mac-only capabilities); the Inspector is a sheet rather than a
/// trailing column. A Settings tab hosts the shared settings form.
struct IOSRootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedSurface) {
            Tab(AppSurface.transcribe.title, systemImage: AppSurface.transcribe.systemImage,
                value: AppSurface.transcribe) {
                NavigationStack {
                    TranscribeView(showsURLField: false)
                        .toolbar { InspectorToolbar(app: app) }
                }
            }
            Tab(AppSurface.record.title, systemImage: AppSurface.record.systemImage,
                value: AppSurface.record) {
                NavigationStack {
                    RecordView(availableModes: [.room])
                        .toolbar { InspectorToolbar(app: app) }
                }
            }
            Tab(AppSurface.library.title, systemImage: AppSurface.library.systemImage,
                value: AppSurface.library) {
                LibraryView()
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
    }
}

/// The inspector-open button shared by the iOS surfaces' navigation bars.
private struct InspectorToolbar: ToolbarContent {
    let app: AppModel

    var body: some ToolbarContent {
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
