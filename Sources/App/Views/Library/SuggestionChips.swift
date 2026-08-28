import SwiftUI
import SwiftData

/// The proactive layer's delivery surface — a quiet, editorial "Suggested" row between the
/// detail view's identity header and the transcript, appearing only once the extraction pass
/// is `.ready` and something actionable was found. Restraint is the design: monochrome capsule
/// chips in the app's quiet-glass language (no banner, no badge, no accent flood — the
/// transcript stays the point). Each chip is one extracted item; tapping it opens the existing
/// Phase 3 draft-then-confirm sheet (routed by the host through `onTap` — this row never
/// writes), and the small × dismisses just that chip, remembered per item on the session.
struct SuggestedActionsRow: View {
    let session: TranscriptSession
    /// The host presents the matching confirm sheet; see `SessionDetailView.suggestionSheet`.
    let onTap: (ActionSuggestion) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let suggestions = ActionSuggestions.suggestions(for: session,
                                                        includeContacts: contactsAvailable)
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: DesignMetrics.spacingS) {
                SectionLabel("Suggested")
                ScrollView(.horizontal) {
                    HStack(spacing: DesignMetrics.spacingS) {
                        ForEach(suggestions) { suggestion in
                            SuggestionChipView(suggestion: suggestion,
                                               onTap: { onTap(suggestion) },
                                               onDismiss: { dismiss(suggestion) })
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                // Bleed the scroll viewport out to the reading column's edge so chips glide
                // under the margin instead of clipping mid-column; the margins keep the
                // resting content aligned with the header above.
                .padding(.horizontal, -DesignMetrics.spacingL)
                .contentMargins(.horizontal, DesignMetrics.spacingL, for: .scrollContent)
            }
            .padding(.bottom, DesignMetrics.spacingS)
        }
    }

    /// The contact surface (`SpeakerAssignmentSheet`) exists only where the system contact
    /// picker does — so contact chips are derived only there.
    private var contactsAvailable: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private func dismiss(_ suggestion: ActionSuggestion) {
        withAnimation(reduceMotion ? nil : DesignMetrics.snappySpring) {
            ActionSuggestions.dismiss(suggestion.id, on: session, in: modelContext)
        }
    }
}

/// One suggestion capsule: leading glyph, the action verb, the item's own text (truncating),
/// and a small tertiary × — the whole body taps through to the confirm sheet, the × only
/// dismisses. Monochrome on the speed control's quaternary capsule so it reads as part of the
/// reading surface, not an upsell.
private struct SuggestionChipView: View {
    let suggestion: ActionSuggestion
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignMetrics.spacingXS) {
            Button(action: onTap) {
                HStack(spacing: DesignMetrics.spacingXS) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verb)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(suggestion.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // Under the scroll axis's ideal-size proposal this clamps to the
                        // text's own width, so short items hug and only long ones truncate.
                        .frame(maxWidth: DesignMetrics.suggestionDetailMaxWidth,
                               alignment: .leading)
                    // The day hint sits outside the truncating frame so a long title can
                    // never swallow the part that makes the chip feel smart.
                    if let day = dayHint {
                        Text("· \(day)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("\(verb): \(detailText)")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: DesignMetrics.suggestionDismissTarget,
                           height: DesignMetrics.suggestionDismissTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion: \(detailText)")
            .accessibilityIdentifier(A11yID.suggestionDismiss(suggestion.id))
        }
        .padding(.vertical, DesignMetrics.suggestionChipVPadding)
        .padding(.leading, DesignMetrics.suggestionChipHPadding)
        .padding(.trailing, DesignMetrics.spacingXS)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityIdentifier(A11yID.suggestion(suggestion.id))
    }

    /// The resolved day, when one exists — "Thu, Jul 17", the hint that makes the chip specific.
    private var dayHint: String? {
        suggestion.date?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// The spoken form for accessibility: item text plus the day hint.
    private var detailText: String {
        guard let dayHint else { return suggestion.detail }
        return "\(suggestion.detail), \(dayHint)"
    }

    private var verb: String {
        switch suggestion.kind {
        case .calendarEvent: "Add to Calendar"
        case .reminder: "Add Reminder"
        case .contact: "Save Contact"
        }
    }

    private var icon: String {
        switch suggestion.kind {
        case .calendarEvent: "calendar.badge.plus"
        case .reminder: "checklist"
        case .contact: "person.crop.circle.badge.plus"
        }
    }
}
