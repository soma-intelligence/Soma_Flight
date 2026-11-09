import Foundation
import Testing
@testable import FlightKit

/// Private flights (no flight number, no airline) and the business jet family: the bundled types, the
/// plan and side drawings, and the Add Past Flight sheet's private choice.
@MainActor @Suite struct PrivateJetTests {
    static let reference = ReferenceData.bundled()
    /// 2026-10-30 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_361_600)

    @Test func businessJetsAreBundled() {
        for id in ["GLF6", "GL7T", "FA7X", "CL35", "C68A", "E55P", "PC24", "E35L"] {
            #expect(Self.reference.type(id)?.family == .bizjet, "\(id)")
        }
        #expect(Self.reference.type("GLF6")?.name == "Gulfstream G650")
        #expect(Self.reference.type("B738")?.family == .b737, "airliners keep their family")
    }

    @Test func businessJetsDrawAsBusinessJets() {
        #expect(PlanFamily(.bizjet) == .bizJet)
        #expect(PlanFamily.bizJet.title == "Business jet")
        let g = PlanFamily.bizJet.plan
        #expect(g.tTail && g.engines.allSatisfy(\.rear) && g.layout == [1, 1])
        #expect(CabinSection(.bizJet).rowWidth < 2 * CabinSection(.bizJet).lining, "two seats and the aisle fit")
        // Three side views, the long-range jet the longest.
        let big = AircraftGeometry.geometry(type: Self.reference.type("GLF6"))
        let mid = AircraftGeometry.geometry(type: Self.reference.type("CL35"))
        let light = AircraftGeometry.geometry(type: Self.reference.type("E55P"))
        #expect(big.family == .bizjet && mid.family == .bizjet && light.family == .bizjet)
        #expect(big.lengthM > mid.lengthM && mid.lengthM > light.lengthM)
        #expect(RouteEstimator.typicalCruiseKmh(.bizjet) == 850)
    }

    @Test func privateFlightIsOneWithoutNumberOrAirline() {
        var f = PastFlight(date: Self.now, ident: "", originIcao: "KTEB", destinationIcao: "KPBI", distanceKm: 1_620)
        #expect(f.isPrivate && Format.ident(f) == "Private")
        f.airline = "NJE"
        #expect(!f.isPrivate)
        f = PastFlight(date: Self.now, ident: "UA990", originIcao: "KSFO", destinationIcao: "LFPG", distanceKm: 8_954)
        #expect(!f.isPrivate && Format.ident(f) == Format.ident("UA990"))
    }

    @Test func privateChoiceDropsNumberAndAirline() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris")!
        let m = PastFlightEditorModel(airport: PastFlightEditorTests.directory.lookup,
                                      today: Date(timeIntervalSince1970: 1_741_932_300), calendar: cal)
        #expect(!m.isPrivate)
        m.origin = "LFPB"; m.destination = "LFMN"
        m.ident = "nope"; m.airline = "AFR"; m.aircraftType = "glf6"; m.registration = "f-hgsa"
        m.isPrivate = true
        let f = try m.flight(now: Self.now, reference: Self.reference, calendar: cal).get()
        #expect(f.ident.isEmpty && f.airline == nil && f.isPrivate, "a bad number is dropped, not refused")
        #expect(f.aircraftType == "GLF6" && f.registration == "F-HGSA")
        // Editing it opens on the private choice.
        #expect(PastFlightEditorModel(flight: f, airport: PastFlightEditorTests.directory.lookup).isPrivate)
    }
}
