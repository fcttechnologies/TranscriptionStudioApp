import SwiftUI

/// App settings — model choices, transcript behavior, and the capture permissions. The
/// engines self-configure for now, so the model pickers are real UI over a real settings
/// object (the chosen model rides into the pipeline events) rather than a dead stub.
/// Presented as a sheet on both platforms (the shell's top-right control).
public struct SettingsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Whisper model", selection: $settings.whisperModel) {
                    ForEach(AppSettings.WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .onChange(of: settings.whisperModel) { _, _ in app.prewarmSelectedModel() }
                Text(settings.whisperModel.detail)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Capture word-level timestamps", isOn: $settings.wordTimestamps)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Applies to new transcription jobs immediately. Recording uses the model loaded at launch — a change takes effect next launch.")
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
