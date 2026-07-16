import Testing
import Foundation
import SwiftData
@testable import TranscriptionKit

/// The pure logic behind opt-in recording-location metadata: the short place-name formatter, the
/// coordinate value type, the Maps-chip policy, and the Spotlight-keyword fold — all deterministic,
/// no CoreLocation/MapKit hardware (the live fix + geocode is an on-device check).

@Suite("PlaceNameFormatter — coarse-first short place names")
struct PlaceNameFormatterTests {

    @Test func pointOfInterestWinsOverEverythingElse() {
        let name = PlaceNameFormatter.shortName(from: .init(
            pointOfInterest: "Blue Bottle Coffee", city: "Oakland",
            shortAddress: "300 Webster St, Oakland"))
        #expect(name == "Blue Bottle Coffee")
    }

    @Test func cityIsPreferredOverTheStreetAddress() {
        // Coarse-first, privacy-forward: the city over a precise street address.
        let name = PlaceNameFormatter.shortName(from: .init(
            city: "San Francisco", shortAddress: "1 Infinite Loop, Cupertino"))
        #expect(name == "San Francisco")
    }

    @Test func shortAddressIsTheLastResort() {
        #expect(PlaceNameFormatter.shortName(from: .init(shortAddress: "1 Infinite Loop, Cupertino"))
                == "1 Infinite Loop, Cupertino")
    }

    @Test func emptyAndWhitespaceComponentsAreIgnored() {
        #expect(PlaceNameFormatter.shortName(from: .init()) == nil)
        #expect(PlaceNameFormatter.shortName(from: .init(pointOfInterest: "   ", city: "Austin")) == "Austin")
        #expect(PlaceNameFormatter.shortName(from: .init(city: "  Austin  ")) == "Austin")
    }
}

@Suite("GeoCoordinate — Codable value type")
struct GeoCoordinateTests {

    @Test func roundTripsThroughCodable() throws {
        let original = GeoCoordinate(latitude: 37.3349, longitude: -122.0090)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeoCoordinate.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("LocationChipPolicy — when a Maps chip shows and where it points")
@MainActor
struct LocationChipPolicyTests {

    private func makeSession() throws -> (ModelContext, TranscriptSession) {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Sync", kind: .roomRecording)
        context.insert(session)
        try context.save()
        return (context, session)
    }

    @Test func noChipWithoutLocation() throws {
        let (_, session) = try makeSession()
        #expect(LocationChipPolicy.chip(for: session) == nil)
    }

    @Test func noChipWithNameButNoCoordinate() throws {
        let (_, session) = try makeSession()
        session.locationName = "Blue Bottle Coffee"
        #expect(LocationChipPolicy.chip(for: session) == nil)
    }

    @Test func noChipWithCoordinateButNoName() throws {
        let (_, session) = try makeSession()
        session.coordinate = GeoCoordinate(latitude: 1, longitude: 2)
        #expect(LocationChipPolicy.chip(for: session) == nil)
    }

    @Test func noChipWhenNameIsBlank() throws {
        let (_, session) = try makeSession()
        session.locationName = "   "
        session.coordinate = GeoCoordinate(latitude: 1, longitude: 2)
        #expect(LocationChipPolicy.chip(for: session) == nil)
    }

    @Test func chipCarriesTrimmedNameAndCoordinate() throws {
        let (_, session) = try makeSession()
        session.locationName = "  Mission District, San Francisco  "
        session.coordinate = GeoCoordinate(latitude: 37.7599, longitude: -122.4148)
        let chip = try #require(LocationChipPolicy.chip(for: session))
        #expect(chip.name == "Mission District, San Francisco")
        #expect(chip.latitude == 37.7599)
        #expect(chip.longitude == -122.4148)
    }
}

@Suite("SessionKeywords — place folds into the Spotlight keyword index")
@MainActor
struct SessionKeywordsTests {

    private func makeSession() throws -> (ModelContext, TranscriptSession) {
        let container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = TranscriptSession(title: "Sync", kind: .roomRecording)
        context.insert(session)
        try context.save()
        return (context, session)
    }

    @Test func placeIsAppendedAfterPeople() throws {
        let (context, session) = try makeSession()
        let ana = TranscriptPerson(name: "Ana"); ana.session = session; context.insert(ana)
        session.locationName = "The Office"
        try context.save()

        #expect(SessionKeywords.values(for: session) == ["Ana", "The Office"])
        // And the entity carries them into its indexed keywords.
        #expect(TranscriptSessionEntity(session).keywords == ["Ana", "The Office"])
    }

    @Test func placeIsNotDuplicatedWhenAlreadyAPersonName() throws {
        let (context, session) = try makeSession()
        let office = TranscriptPerson(name: "The Office"); office.session = session; context.insert(office)
        session.locationName = "the office"   // case-insensitive duplicate
        try context.save()
        #expect(SessionKeywords.values(for: session) == ["The Office"])
    }

    @Test func noPlaceKeywordWhenLocationIsAbsentOrBlank() throws {
        let (context, session) = try makeSession()
        let ana = TranscriptPerson(name: "Ana"); ana.session = session; context.insert(ana)
        try context.save()
        #expect(SessionKeywords.values(for: session) == ["Ana"])

        session.locationName = "   "
        try context.save()
        #expect(SessionKeywords.values(for: session) == ["Ana"])
    }
}
