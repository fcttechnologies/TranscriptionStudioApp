import SwiftUI
import MapKit
import CoreLocation

/// The recording-location chip for a session's detail header — one quiet capsule showing the
/// resolved place name, tapping through to Maps at the recorded coordinate. A pure value the view
/// renders; all "should this chip exist, and what does it point at" logic lives in
/// `LocationChipPolicy` (unit-tested), the view stays a thin renderer.
struct LocationChip: Equatable, Sendable {
    /// The short human place name shown on the chip (never empty — the policy requires it).
    let name: String
    let latitude: Double
    let longitude: Double

    init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Derives a session's location chip — the pure "is there a location worth showing, and where does
/// it point" mapping. A chip needs both a non-empty place name (its label) and a coordinate (the
/// Maps target); a session with neither, or with only one, shows nothing.
enum LocationChipPolicy {
    static func chip(for session: TranscriptSession) -> LocationChip? {
        guard let name = session.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let coordinate = session.coordinate else { return nil }
        return LocationChip(name: name,
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude)
    }
}

/// One quiet location capsule: a pin glyph + the place name, tapping opens Maps at the recorded
/// coordinate. Monochrome on the same quaternary capsule the suggestion chips use, so it reads as
/// part of the identity header rather than an accent — the detail view's Apple-Music-level
/// restraint (one chip, never a banner).
struct LocationChipView: View {
    let chip: LocationChip

    var body: some View {
        Button(action: openInMaps) {
            HStack(spacing: DesignMetrics.spacingXS) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(chip.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, DesignMetrics.suggestionChipVPadding)
            .padding(.horizontal, DesignMetrics.suggestionChipHPadding)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Open \(chip.name) in Maps")
        .accessibilityIdentifier("session.location")
    }

    /// Rebuild an `MKMapItem` from the persisted coordinate + name and hand it to Maps. Uses the
    /// modern `init(location:address:)` — `init(placemark:)`/`placemark` are deprecated in SDK 27.
    private func openInMaps() {
        let coordinate = CLLocationCoordinate2D(latitude: chip.latitude, longitude: chip.longitude)
        let address = MKAddress(fullAddress: chip.name, shortAddress: chip.name)
        let mapItem = MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                     longitude: coordinate.longitude),
                                address: address)
        mapItem.name = chip.name
        _ = mapItem.openInMaps()
    }
}
