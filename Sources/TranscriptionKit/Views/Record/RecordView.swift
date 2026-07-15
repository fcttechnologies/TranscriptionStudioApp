import SwiftUI

/// The Record surface — the showcase centerpiece. Idle: pick a mode (Room / Meeting), with
/// Meeting surfacing its real screen-recording permission ladder and Room surfacing a mic card
/// when access is denied. Preparing: the engine download/load progress. Live: the recording
/// layout. Feel: alive, precise, calm — springs, no gimmicks.
public struct RecordView: View {
    let availableModes: [RecordingController.Mode]

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var selectedMode: RecordingController.Mode = .room
    @State private var screenStatus: ScreenCapturePermission.Status = .granted
    @State private var micStatus: MicrophonePermission.Status = .authorized

    public init(availableModes: [RecordingController.Mode] = RecordingController.Mode.allCases) {
        self.availableModes = availableModes
    }

    public var body: some View {
        Group {
            switch app.recording.phase {
            case .preparing(let progress):
                RecordPreparingView(progress: progress)
            case .recording, .finishing:
                RecordLiveView()
            case .idle:
                setup
            }
        }
        .navigationTitle("Record")
        .animation(reduceMotion ? nil : DesignMetrics.standardSpring, value: app.recording.isActive)
        .onAppear(perform: refreshPermissions)
        .onChange(of: app.recording.phase) { old, new in
            // Donate only on a real preparing → recording transition (a successful start),
            // never on resume-from-pause (phase stays .recording) or a failed prepare.
            if case .recording = new, case .preparing = old {
                let mode = app.recording.mode
                Task { await TranscriptionIntentDonations.donateStartRecording(mode: mode) }
            }
        }
        .alert("Couldn't record",
               isPresented: Binding(get: { app.recording.lastError != nil },
                                    set: { if !$0 { app.recording.clearError() } }),
               presenting: app.recording.lastError) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: Setup (idle)

    private var setup: some View {
        ScrollView {
            VStack(spacing: DesignMetrics.spacingXL) {
                VStack(spacing: DesignMetrics.spacingS) {
                    SectionLabel("Mode")
                    ForEach(availableModes) { mode in
                        ModeCard(mode: mode, isSelected: selectedMode == mode) {
                            withAnimation(reduceMotion ? nil : DesignMetrics.snappySpring) { selectedMode = mode }
                            refreshPermissions()
                        }
                    }
                }
                if selectedMode == .meeting {
                    ScreenRecordingCard(status: screenStatus, action: grantScreenRecording,
                                        openSettings: { openURL(ScreenCapturePermission.settingsURL) })
                        .transition(.motionAware(.top, reduceMotion: reduceMotion))
                }
                if selectedMode == .room && micStatus == .denied {
                    MicrophoneCard { openURL(MicrophonePermission.settingsURL) }
                        .transition(.motionAware(.top, reduceMotion: reduceMotion))
                }
                recordButton
                    .padding(.top, DesignMetrics.spacingS)
            }
            .padding(DesignMetrics.spacingXL)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    private var canStart: Bool {
        switch selectedMode {
        case .room: micStatus != .denied
        case .meeting: screenStatus == .granted
        }
    }

    private var recordButton: some View {
        Button {
            app.recording.start(mode: selectedMode)
        } label: {
            VStack(spacing: DesignMetrics.spacingS) {
                ZStack {
                    Circle()
                        .fill(canStart ? Color.red : Color.secondary.opacity(0.4))
                        .frame(width: DesignMetrics.recordControlSize, height: DesignMetrics.recordControlSize)
                    Image(systemName: "record.circle")
                        .font(.system(size: DesignMetrics.recordGlyphSize, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Start recording").font(.subheadline.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canStart)
        .opacity(canStart ? 1 : 0.6)
        .accessibilityIdentifier("record.start")
        .accessibilityLabel("Start recording")
    }

    // MARK: Permission flow

    private func refreshPermissions() {
        micStatus = MicrophonePermission.preflight()
        screenStatus = ScreenCapturePermission.preflight()
    }

    private func grantScreenRecording() {
        withAnimation(reduceMotion ? nil : DesignMetrics.standardSpring) {
            screenStatus = ScreenCapturePermission.request()
        }
    }
}

/// The preparing phase — model download/load progress, shown before capture begins.
private struct RecordPreparingView: View {
    let progress: EnginePreparationProgress

    var body: some View {
        VStack(spacing: DesignMetrics.spacingL) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction) {
                    Text(progress.phase)
                } currentValueLabel: {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .frame(maxWidth: 320)
            } else {
                ProgressView { Text(progress.phase) }
            }
        }
        .padding(DesignMetrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("record.preparing")
    }
}

/// A selectable mode card with press feedback and a clear selected state.
private struct ModeCard: View {
    let mode: RecordingController.Mode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignMetrics.spacingM) {
                Image(systemName: mode.systemImage)
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title).font(.headline)
                    Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .padding(DesignMetrics.spacingL)
            .background {
                RoundedRectangle(cornerRadius: DesignMetrics.modeCardCorner, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignMetrics.modeCardCorner, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.5)) : AnyShapeStyle(.separator), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("record.mode.\(mode.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The meeting-mode Screen Recording permission ladder — the real macOS TCC flow: request the
/// grant, explain the restart-after-first-grant quirk, and deep-link to System Settings on denial.
private struct ScreenRecordingCard: View {
    let status: ScreenCapturePermission.Status
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            Label {
                Text(title).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            switch status {
            case .granted:
                EmptyView()
            case .notDetermined:
                PrimaryButton("Grant Screen Recording", systemImage: "lock.open", action: action)
            case .needsRestart:
                EmptyView()
            case .denied:
                PrimaryButton("Open System Settings", systemImage: "gear", action: openSettings)
            }
        }
        .padding(DesignMetrics.spacingL)
        .cardStyle(cornerRadius: DesignMetrics.modeCardCorner)
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.modeCardCorner)
            .strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }

    private var icon: String {
        switch status {
        case .granted: "checkmark.shield.fill"
        case .notDetermined: "questionmark.circle"
        case .needsRestart: "arrow.clockwise.circle"
        case .denied: "exclamationmark.shield"
        }
    }
    private var tint: Color {
        switch status {
        case .granted: .green
        case .notDetermined: .secondary
        case .needsRestart: .blue
        case .denied: .orange
        }
    }
    private var title: String {
        switch status {
        case .granted: "Ready to capture the meeting"
        case .notDetermined: "Screen recording permission"
        case .needsRestart: "Relaunch to finish enabling"
        case .denied: "Permission denied"
        }
    }
    private var explanation: String {
        switch status {
        case .granted:
            "System audio and your mic will be captured as separate tracks — you're attributed as “Me”, everyone else is diarized."
        case .notDetermined:
            "Meeting mode captures system audio via ScreenCaptureKit, which macOS gates behind the Screen Recording permission. Everything stays on this device."
        case .needsRestart:
            "Screen Recording is granted. macOS needs Transcription Studio to relaunch before it can capture — quit and reopen, then start the meeting."
        case .denied:
            "Screen Recording is turned off for Transcription Studio. Enable it in System Settings › Privacy & Security › Screen Recording, then relaunch."
        }
    }
}

/// The room-mode microphone card — shown only when mic access is denied, with a deep link to
/// the microphone privacy settings so the recording isn't started into silence.
private struct MicrophoneCard: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            Label {
                Text("Microphone access denied").font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "mic.slash").foregroundStyle(.orange)
            }
            Text("Room recording needs the microphone. Enable it for Transcription Studio in System Settings, then try again.")
                .font(.caption).foregroundStyle(.secondary)
            PrimaryButton("Open System Settings", systemImage: "gear", action: openSettings)
        }
        .padding(DesignMetrics.spacingL)
        .cardStyle(cornerRadius: DesignMetrics.modeCardCorner)
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.modeCardCorner)
            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
    }
}
