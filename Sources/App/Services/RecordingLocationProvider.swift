import Foundation
import CoreLocation
import MapKit

/// Captures the coarse place a live recording was made in — one location fix at session start,
/// reverse-geocoded to a short human place name — when the user has opted in
/// (`AppSettings.locationCaptureEnabled`). Everything degrades **silently** to no location: a
/// denied/restricted permission, a fix that never arrives within the timeout, or a failed
/// geocode all return `nil`, never an error the recording surface has to show.
///
/// Uses the modern Swift-concurrency one-shot: `CLLocationUpdate.liveUpdates()` (the streamlined
/// replacement for a delegate-driven `CLLocationManager.requestLocation`), taking the first
/// update that carries a location and stopping — the iOS-27 floor makes it unconditionally
/// available. Reverse geocoding uses `MKReverseGeocodingRequest` (`CLGeocoder` is deprecated in
/// the 26/27 SDKs — "use MapKit"), reading a coarse place name off the resolved `MKMapItem`; the
/// Maps deep-link chip later rebuilds its own `MKMapItem` from the persisted coordinate.
@MainActor
final class RecordingLocationProvider {
    /// A resolved recording location: the short place name (nil when geocoding produced nothing
    /// usable, even though a fix succeeded) plus the raw coordinate for the Maps deep link.
    struct CapturedLocation: Sendable, Equatable {
        var name: String?
        var latitude: Double
        var longitude: Double

        init(name: String?, latitude: Double, longitude: Double) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// Used only to read the current authorization and prompt for When-In-Use on first capture —
    /// the fix itself comes from `CLLocationUpdate.liveUpdates()`.
    private let manager = CLLocationManager()
    /// How long to wait for the first location fix before giving up (silent degrade).
    private let timeout: Duration

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// Capture one location and reverse-geocode it to a short place name. Returns `nil` — never
    /// throws, never surfaces an error — when permission is denied, no fix arrives in time, or the
    /// coordinate can't be resolved to a name.
    func capture() async -> CapturedLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        guard let coordinate = await Self.firstFix(timeout: timeout) else { return nil }
        let name = await Self.reverseGeocodedName(coordinate: coordinate)
        return CapturedLocation(name: name,
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude)
    }

    /// The first location fix from the live-updates stream, or `nil` if the user isn't authorized
    /// or none arrives within `timeout`. Nonisolated: it touches no actor-bound state, and the
    /// stream's `CLLocationUpdate`s are `Sendable`.
    private nonisolated static func firstFix(timeout: Duration) async -> GeoCoordinate? {
        await withTaskGroup(of: GeoCoordinate?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationDenied
                            || update.authorizationDeniedGlobally
                            || update.authorizationRestricted {
                            return nil
                        }
                        if let location = update.location {
                            return GeoCoordinate(latitude: location.coordinate.latitude,
                                                 longitude: location.coordinate.longitude)
                        }
                    }
                    return nil
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Reverse-geocode a coordinate to a short place name via `MKReverseGeocodingRequest`,
    /// extracting the coarse strings off the resolved `MKMapItem` and handing them to the pure
    /// `PlaceNameFormatter`. On the main actor because MapKit's request/result types aren't
    /// `Sendable` (the I/O is an `await` that suspends, not a main-thread block). `nil` when
    /// geocoding fails or yields nothing usable.
    @MainActor
    static func reverseGeocodedName(coordinate: GeoCoordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItem = try? await request.mapItems.first else { return nil }
        // `name` is a real landmark/business label only when the item is a categorized point of
        // interest; for a plain address it's the street, which we deliberately don't surface
        // (coarse-first, privacy-forward — prefer the city).
        let components = PlaceNameComponents(
            pointOfInterest: mapItem.pointOfInterestCategory != nil ? mapItem.name : nil,
            city: mapItem.addressRepresentations?.cityName,
            shortAddress: mapItem.address?.shortAddress)
        return PlaceNameFormatter.shortName(from: components)
    }
}

/// The coarse address components a short place name is built from — read off an `MKMapItem` so the
/// name-formatting logic is a pure, directly-testable function over plain strings.
struct PlaceNameComponents: Sendable, Equatable {
    /// A landmark / business name, only when the map item is a categorized point of interest
    /// ("Blue Bottle Coffee").
    var pointOfInterest: String?
    /// City name ("San Francisco") — the coarse, privacy-forward default.
    var city: String?
    /// The short address (street + city) — a last resort when there's no POI or city.
    var shortAddress: String?

    init(pointOfInterest: String? = nil, city: String? = nil, shortAddress: String? = nil) {
        self.pointOfInterest = pointOfInterest
        self.city = city
        self.shortAddress = shortAddress
    }
}

/// Builds a short, human place name from reverse-geocoded components — pure and unit-tested.
/// Coarse-first, so the tag stays privacy-forward: a named landmark when the coordinate is one,
/// otherwise the city, and only as a last resort the street-level short address.
enum PlaceNameFormatter {
    static func shortName(from components: PlaceNameComponents) -> String? {
        func cleaned(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        if let poi = cleaned(components.pointOfInterest) { return poi }
        if let city = cleaned(components.city) { return city }
        return cleaned(components.shortAddress)
    }
}
