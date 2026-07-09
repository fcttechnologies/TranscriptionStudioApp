import SwiftUI

/// A live transcription job rendered as a card: a vertical step trail with the active stage
/// pulsing, a progress bar, the current stage text, and terminal states (done / failed /
/// cancelled) shown as human sentences — never a raw error. The web app's poll-and-refresh
/// job UX, done native and legible.
public struct JobProgressCard: View {
    let job: TranscriptionJob
    var onCancel: () -> Void
    var onOpen: () -> Void
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(job: TranscriptionJob,
                onCancel: @escaping () -> Void,
                onOpen: @escaping () -> Void,
                onDismiss: @escaping () -> Void) {
        self.job = job
        self.onCancel = onCancel
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            header
            steps
            if job.state == .running || job.state == .queued {
                ProgressView(value: job.progress)
                    .tint(.accentColor)
                    .frame(height: DesignMetrics.jobProgressHeight)
            }
            footer
        }
        .padding(DesignMetrics.spacingL)
        .cardStyle(cornerRadius: DesignMetrics.jobCardCorner, elevated: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(job.title))
    }

    private var header: some View {
        HStack(spacing: DesignMetrics.spacingS) {
            statusIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(job.stageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if job.state == .done {
                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .queued, .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(job.steps.enumerated()), id: \.offset) { index, label in
                stepRow(index: index, label: label, isLast: index == job.steps.count - 1)
            }
        }
    }

    private func stepRow(index: Int, label: String, isLast: Bool) -> some View {
        let done = index < job.activeStepIndex || job.state == .done
        let active = index == job.activeStepIndex && (job.state == .running || job.state == .queued)
        return HStack(alignment: .top, spacing: DesignMetrics.spacingM) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.3)))
                        .frame(width: DesignMetrics.jobStepDotSize, height: DesignMetrics.jobStepDotSize)
                    if active && !reduceMotion {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                            .frame(width: DesignMetrics.jobStepDotSize + 6,
                                   height: DesignMetrics.jobStepDotSize + 6)
                            .scaleEffect(active ? 1 : 0.6)
                            .opacity(active ? 0 : 1)
                            .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: active)
                    }
                }
                .frame(width: DesignMetrics.jobStepDotSize + 6, height: DesignMetrics.jobStepDotSize + 6)
                if !isLast {
                    Rectangle()
                        .fill(done ? Color.green.opacity(0.5) : Color.secondary.opacity(0.2))
                        .frame(width: DesignMetrics.jobStepConnectorWidth, height: 16)
                }
            }
            Text(label)
                .font(.subheadline)
                .foregroundStyle(active ? .primary : (done ? .primary : .secondary))
                .fontWeight(active ? .semibold : .regular)
                .padding(.bottom, isLast ? 0 : DesignMetrics.spacingS)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch job.state {
        case .queued, .running:
            Button(role: .cancel, action: onCancel) { Text("Cancel") }
                .controlSize(.small)
        case .error:
            HStack(spacing: DesignMetrics.spacingS) {
                Text(job.errorMessage ?? "Something went wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Dismiss", action: onDismiss).controlSize(.small)
            }
        case .cancelled:
            Button("Dismiss", action: onDismiss).controlSize(.small)
        case .done:
            EmptyView()
        }
    }
}
