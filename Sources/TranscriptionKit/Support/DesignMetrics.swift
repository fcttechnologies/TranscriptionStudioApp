import Foundation
import SwiftUI

/// The design-token sheet. The convention: **no magic numbers in views** — every spacing,
/// size, corner radius, duration, and tuning value lives here so the look is adjustable in
/// one place. Group constants by surface; add groups as surfaces land.
public enum DesignMetrics {
    // MARK: Global rhythm
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 12
    public static let spacingL: CGFloat = 16
    public static let spacingXL: CGFloat = 24

    public static let cornerS: CGFloat = 8
    public static let cornerM: CGFloat = 12
    public static let cornerL: CGFloat = 16

    /// Minimum hit target (HIG).
    public static let hitTarget: CGFloat = 44

    // MARK: Motion (see motion-craft: UI under 300ms, springs critically damped by default)
    public static let pressFeedbackDuration: Double = 0.16
    public static let standardSpring = Animation.spring(duration: 0.35, bounce: 0)
    public static let snappySpring = Animation.spring(duration: 0.25, bounce: 0)

    // MARK: Transcript
    /// Per-speaker accent colors (speaker 0–3 + "me"). Semantic system colors elsewhere.
    public static let speakerPalette: [Color] = [.blue, .orange, .purple, .teal]
    public static let meColor: Color = .green
}
