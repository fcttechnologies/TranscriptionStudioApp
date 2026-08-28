import SwiftUI

/// Transcription work in flight, as a quiet section above the feed: one row per running
/// (or failed) job with its live stage and progress. A finished job's row disappears as its
/// session drops into the list below — completion reads as arrival, not a card to dismiss.
struct ActiveWorkSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Everything worth a row: live work plus failures/cancellations awaiting dismissal.
    /// Done jobs are excluded — their session row is the completion state.
    private var visibleJobs: [TranscriptionJob] {
        app.jobs.jobs
            .filter { $0.state != .done }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let jobs = visibleJobs
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: DesignMetrics.feedRowSpacing) {
                SectionLabel("In progress")
                    .padding(.leading, DesignMetrics.spacingXS)
                ForEach(jobs) { job in
                    ActiveJobRow(job: job,
                                 onCancel: { job.cancel() },
                                 onDismiss: { app.jobs.remove(job) })
                        .transition(.motionAware(.top, reduceMotion: reduceMotion))
                }
            }
            .animation(reduceMotion ? nil : DesignMetrics.standardSpring, value: jobs.map(\.id))
            .accessibilityIdentifier(A11yID.homeActiveWork)
        }
    }
}

/// One in-flight job: status glyph, title + live stage text, a thin progress track, and the
/// row's one action (cancel while running, dismiss after a failure/cancellation).
struct ActiveJobRow: View {
    let job: TranscriptionJob
    let onCancel: () -> Void
    let onDismiss: () -> Void

    private var isLive: Bool { job.state == .running || job.state == .queued }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignMetrics.spacingM) {
            HStack(spacing: DesignMetrics.spacingM) {
                statusIcon
                    .frame(width: 34, height: 34)
                    .background(.quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: DesignMetrics.cornerS, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                Button {
                    isLive ? onCancel() : onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary.opacity(0.5), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(isLive ? "Cancel" : "Dismiss")
            }
            if isLive {
                ProgressView(value: job.progress)
                    .tint(.accentColor)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, DesignMetrics.spacingL)
        .padding(.vertical, DesignMetrics.spacingM)
        .cardStyle(cornerRadius: DesignMetrics.cornerL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(job.title), \(statusLine)"))
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

    private var statusLine: String {
        if job.state == .error, let message = job.errorMessage { return message }
        return job.stageText
    }
}
