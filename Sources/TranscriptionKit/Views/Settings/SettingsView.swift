import SwiftUI

/// App settings — the speech model (fixed at large-v3-turbo), the diarizer backend, transcript
/// behavior, capture permissions, and model storage.
/// Presented as a sheet on both platforms (the shell's top-right control).
public struct SettingsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("Speech model", value: settings.whisperModel.displayName)
                Toggle("Capture word-level timestamps", isOn: $settings.wordTimestamps)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("On-device Whisper large-v3-turbo — the speed/accuracy sweet spot.")
            }
            Section("Diarization") {
                Picker("Backend", selection: $settings.diarizerBackend) {
                    ForEach(AppSettings.DiarizerBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.diarizerBackend.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcript") {
                Toggle("Auto-follow the live transcript", isOn: $settings.autoFollowTranscript)
            }
            PermissionsSection()
            StorageSection()
            Section {
                LabeledContent("On-device", value: "All processing stays local")
                LabeledContent("Version", value: "0.1.0")
            } footer: {
                Text("Transcription Studio runs entirely on this device. Nothing is uploaded.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
