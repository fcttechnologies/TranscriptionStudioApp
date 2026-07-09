import SwiftUI

/// App settings — model choices and transcript behavior. The engines self-configure for now,
/// so the model pickers are real UI over a real settings object (the chosen model rides into
/// the pipeline events) rather than a dead stub. Hosted by the Mac Settings scene and shown
/// as a sheet on iOS.
public struct SettingsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Speech recognition") {
                Picker("Whisper model", selection: $settings.whisperModel) {
                    ForEach(AppSettings.WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(settings.whisperModel.detail)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Capture word-level timestamps", isOn: $settings.wordTimestamps)
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
            Section {
                LabeledContent("On-device", value: "All processing stays local")
                LabeledContent("Version", value: "0.1.0")
            } footer: {
                Text("Transcription Studio runs entirely on this device. Nothing is uploaded.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 420, minHeight: 420)
    }
}
