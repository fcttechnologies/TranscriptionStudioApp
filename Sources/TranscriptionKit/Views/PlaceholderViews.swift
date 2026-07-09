import SwiftUI

/// A surface the UI lane hasn't landed yet. Every placeholder names its lane so a build
/// is honest about what's real.
public struct LanePlaceholderView: View {
    public let title: String
    public let systemImage: String
    public let laneNote: String

    public init(title: String, systemImage: String, laneNote: String) {
        self.title = title
        self.systemImage = systemImage
        self.laneNote = laneNote
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(laneNote)
        }
    }
}
