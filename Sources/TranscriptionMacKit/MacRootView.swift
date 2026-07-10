import SwiftUI
import TranscriptionKit

/// The Mac shell: a sidebar of the three surfaces (with live running-job / recording
/// indicators), the selected surface as the detail, and the Inspector as a trailing column.
/// Keyboard shortcuts live in `AppCommands` on the scene.
public struct MacRootView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(AppSurface.allCases, selection: $app.selectedSurface) { surface in
                SurfaceRow(surface: surface,
                           runningJobs: app.jobs.jobs.filter { $0.state == .running || $0.state == .queued }.count,
                           isRecording: surface == .record && app.recording.isActive)
                    .tag(surface)
            }
            .navigationTitle("Transcription Studio")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            detail(for: app.selectedSurface)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            app.isInspectorPresented.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .keyboardShortcut("i", modifiers: .command)
                        .accessibilityIdentifier("toolbar.inspectorToggle")
                    }
                }
                .inspector(isPresented: $app.isInspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: DesignMetrics.inspectorMinWidth,
                                              ideal: DesignMetrics.inspectorWidth,
                                              max: DesignMetrics.inspectorMaxWidth)
                }
        }
    }

    @ViewBuilder
    private func detail(for surface: AppSurface) -> some View {
        switch surface {
        case .transcribe: TranscribeView(showsURLField: true)
        case .record: RecordView(availableModes: RecordingController.Mode.allCases)
        case .library: LibraryView()
        }
    }
}

/// A sidebar row with the surface label and a live indicator (running-job count / recording).
private struct SurfaceRow: View {
    let surface: AppSurface
    let runningJobs: Int
    let isRecording: Bool

    var body: some View {
        Label(surface.title, systemImage: surface.systemImage)
            .badge(surface == .transcribe && runningJobs > 0 ? runningJobs : 0)
            .overlay(alignment: .trailing) {
                if isRecording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .accessibilityLabel("Recording")
                }
            }
    }
}

/// Scene commands: ⌘N new recording, ⌘L library, ⌘I inspector toggle.
public struct AppCommands: Commands {
    let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var body: some Commands {
        // Replace the default "New Window" (⌘N) so ⌘N starts a recording, per the app's shell.
        CommandGroup(replacing: .newItem) {
            Button("New Recording") {
                app.selectedSurface = .record
                if !app.recording.isActive { app.recording.start(mode: .room) }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Show Library") { app.selectedSurface = .library }
                .keyboardShortcut("l", modifiers: .command)
            Button(app.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                app.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}
