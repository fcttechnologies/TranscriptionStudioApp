import SwiftUI

/// The Record surface — the showcase centerpiece. Idle: pick a mode (Room / Meeting), with
/// Meeting surfacing its screen-recording permission states. Live: a level meter, a scrolling
/// waveform, the elapsed clock, the speaker-attributed live transcript, and calm controls.
/// Feel: alive, precise, calm — springs, no gimmicks.
public struct RecordView: View {
    let availableModes: [RecordingController.Mode]

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedMode: RecordingController.Mode = .room
    @State private var meetingPermission: MeetingPermission = .notDetermined

    public init(availableModes: [RecordingController.Mode] = RecordingController.Mode.allCases) {
        self.availableModes = availableModes
    }

    public var body: some View {
        Group {
            if app.recording.isRecording {
                RecordLiveView()
            } else {
                setup
            }
        }
        .navigationTitle("Record")
        .animation(reduceMotion ? nil : DesignMetrics.standardSpring, value: app.recording.isRecording)
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
                        }
                    }
                }
                if selectedMode == .meeting {
                    MeetingPermissionCard(state: meetingPermission) {
                        withAnimation(reduceMotion ? nil : DesignMetrics.standardSpring) {
                            meetingPermission = meetingPermission.next
                        }
                    }
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
        selectedMode != .meeting || meetingPermission == .granted
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
}

/// The (mock) meeting-capture permission ladder — a stand-in for the real ScreenCaptureKit
/// TCC flow that Lane B wires: not determined → needs the screen-recording grant → granted.
enum MeetingPermission {
    case notDetermined, needsGrant, granted

    var next: MeetingPermission {
        switch self {
        case .notDetermined: .needsGrant
        case .needsGrant: .granted
        case .granted: .granted
        }
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

/// The meeting-mode permission explainer — shows the current state and the next action.
private struct MeetingPermissionCard: View {
    let state: MeetingPermission
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            Label {
                Text(title).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            if state != .granted {
                PrimaryButton(buttonTitle, systemImage: "lock.open", action: action)
            }
        }
        .padding(DesignMetrics.spacingL)
        .cardStyle(cornerRadius: DesignMetrics.modeCardCorner)
        .overlay(RoundedRectangle(cornerRadius: DesignMetrics.modeCardCorner)
            .strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }

    private var icon: String {
        switch state {
        case .notDetermined: "questionmark.circle"
        case .needsGrant: "exclamationmark.shield"
        case .granted: "checkmark.shield.fill"
        }
    }
    private var tint: Color {
        switch state {
        case .notDetermined: .secondary
        case .needsGrant: .orange
        case .granted: .green
        }
    }
    private var title: String {
        switch state {
        case .notDetermined: "Screen recording permission"
        case .needsGrant: "Permission needed"
        case .granted: "Ready to capture the meeting"
        }
    }
    private var explanation: String {
        switch state {
        case .notDetermined:
            "Meeting mode captures system audio via ScreenCaptureKit, which macOS gates behind the Screen Recording permission. Everything stays on this device."
        case .needsGrant:
            "Grant Transcription Studio the Screen Recording permission in System Settings, then relaunch to capture meeting audio."
        case .granted:
            "System audio and your mic will be captured as separate tracks — you're attributed as “Me”, everyone else is diarized."
        }
    }
    private var buttonTitle: LocalizedStringKey {
        state == .notDetermined ? "Continue" : "Grant Screen Recording"
    }
}
