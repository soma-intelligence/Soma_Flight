import Testing
import Foundation
import SwiftUI
import CoreGraphics
import FlightCore
@testable import FlightKit

private func stats(classes: SeatClassCounts = SeatClassCounts(economy: 0, premiumEconomy: 0, business: 0, first: 0),
                   positions: PositionCounts = PositionCounts(window: 0, middle: 0, aisle: 0),
                   reasons: ReasonCounts = ReasonCounts(personal: 0, business: 0),
                   favourite: SeatTally? = nil) -> AircraftStats {
    var s = AircraftStats.empty
    s.seatClasses = classes
    s.seatPositions = positions
    s.reasons = reasons
    s.favouriteSeat = favourite
    return s
}

@Suite struct AircraftStatsViewTests {
    @Test func ageCopy() {
        #expect(AircraftStatsCopy.ageCopy(months: 0) == "0 months")
        #expect(AircraftStatsCopy.ageCopy(months: 1) == "1 month")
        #expect(AircraftStatsCopy.ageCopy(months: 7) == "7 months")
        #expect(AircraftStatsCopy.ageCopy(months: 11) == "11 months")
        #expect(AircraftStatsCopy.ageCopy(months: 12) == "1 year")
        #expect(AircraftStatsCopy.ageCopy(months: 23) == "1 year")
        #expect(AircraftStatsCopy.ageCopy(months: 29 * 12 + 5) == "29 years")
        #expect(AircraftStatsCopy.ageOld(months: 120) == "10 years old")
    }

    @Test func decadeLabels() {
        let decades = [DecadeCount(decade: 1990, aircraft: 1), DecadeCount(decade: 2000, aircraft: 0),
                       DecadeCount(decade: 2010, aircraft: 9)]
        #expect(AircraftStatsCopy.decadeLabels(decades) == ["1990s", "2000s", "2010s"])
        #expect(AircraftStatsCopy.decadeLabels([]).isEmpty)
    }

    @Test func donutHiddenWhenEmpty() {
        let empty = stats()
        #expect(AircraftStatsCopy.classDonut(empty).isHidden)
        #expect(AircraftStatsCopy.seatDonut(empty).isHidden)
        #expect(AircraftStatsCopy.reasonDonut(empty).isHidden)

        let some = stats(classes: SeatClassCounts(economy: 54, premiumEconomy: 0, business: 2, first: 0),
                         positions: PositionCounts(window: 5, middle: 6, aisle: 24),
                         reasons: ReasonCounts(personal: 33, business: 20),
                         favourite: SeatTally(seat: "20D", flights: 2))
        let cls = AircraftStatsCopy.classDonut(some)
        #expect(!cls.isHidden)
        #expect(cls.centerTitle == "Top class" && cls.centerValue == "Economy")
        #expect(cls.slices.map(\.percent) == [96, 0, 4, 0])
        let seat = AircraftStatsCopy.seatDonut(some)
        #expect(seat.centerTitle == "Top seat" && seat.centerValue == "20D")
        #expect(seat.slices.map(\.label) == ["Aisle", "Middle", "Window"])
        #expect(seat.slices.map(\.percent) == [69, 17, 14])
        let reason = AircraftStatsCopy.reasonDonut(some)
        #expect(reason.centerTitle == "Top reason" && reason.centerValue == "Personal")
        #expect(reason.slices.map(\.percent) == [62, 38])
        #expect(AircraftStatsCopy.favoriteSeat(some)?.title == "Favorite seat")
        #expect(AircraftStatsCopy.favoriteSeat(some)?.value == "20D (2 times)")

        // Only reasons known: the class and seat donuts still hide.
        let reasonsOnly = stats(reasons: ReasonCounts(personal: 1, business: 0))
        #expect(AircraftStatsCopy.classDonut(reasonsOnly).isHidden)
        #expect(!AircraftStatsCopy.reasonDonut(reasonsOnly).isHidden)
    }

    @MainActor @Test func factsMissingHidesAges() async {
        let noFacts = PassportStore(history: FakeHistoryService(), asOf: Date(timeIntervalSince1970: 1_793_000_000))
        await noFacts.load()
        #expect(noFacts.aircraft.totalTypes > 0)
        #expect(!AircraftStatsCopy.showsAges(noFacts.aircraft))
        #expect(noFacts.aircraft.decades.isEmpty)
        #expect(await noFacts.leadTailAge() == nil)

        let withFacts = PassportStore(history: FakeHistoryService(), facts: FakeAircraftFactsService(),
                                      asOf: Date(timeIntervalSince1970: 1_793_000_000))
        await withFacts.load()
        #expect(AircraftStatsCopy.showsAges(withFacts.aircraft))
        #expect(!AircraftStatsCopy.decadeLabels(withFacts.aircraft.decades).isEmpty)
        // The lead tail's age comes from the core run on its own flights.
        #expect(await withFacts.leadTailAge() != nil)
    }

    /// The store matches tails the way the core keys them, so a messy registration still finds its age.
    @Test func registrationKeyMatchesTheCore() {
        let messy = FlightKit.PastFlight(date: Date(timeIntervalSince1970: 1_767_268_800), ident: "AF84",
                                         originIcao: "LFPG", destinationIcao: "KSFO", aircraftType: "B77W",
                                         registration: "  f-gsqi ", distanceKm: 8_950).coreFlight
        let s = FlightCore.computeAircraftStats(flights: [messy], year: nil, types: [], facts: [], asOf: 0)
        #expect(s.tails.first?.registration == PassportStore.registrationKey("  f-gsqi "))
        #expect(PassportStore.registrationKey("   ") == nil)
        #expect(PassportStore.registrationKey(nil) == nil)
    }

    @Test func headerCopy() {
        let most = TypeTally(icaoType: "B77W", flights: 8, minutes: 90 * 60 - 20, distanceKm: 1)
        #expect(AircraftStatsCopy.flightsAndHours(most) == "8 flights · 90 hours")
        var s = AircraftStats.empty
        s.manufacturers = [Share(key: "Boeing", flights: 30, percent: 56)]
        #expect(AircraftStatsCopy.makerChip(s) == "56% Boeing")
        #expect(AircraftStatsCopy.deliveryYear(1_654_732_800) == "2022")
        #expect(AircraftStatsCopy.deliveryDay(1_654_732_800) == "6/9/2022")
    }

    @Test func tailCountryFromRegistration() {
        let cases: [(String, String?)] = [
            ("N370DN", "US"), ("G-ZBKD", "GB"), ("F-GSQI", "FR"), ("D-AIXA", "DE"), ("C-FIVQ", "CA"),
            ("VH-OQA", "AU"), ("JA873J", "JP"), ("HL7630", "KR"), ("9V-SMF", "SG"), ("A6-EDA", "AE"),
            ("HB-JNA", "CH"), ("EI-DEI", "IE"), ("PH-BKL", "NL"), ("OO-SSA", "BE"), ("EC-MXV", "ES"),
            ("I-ADLZ", "IT"), ("LN-RKF", "NO"), ("SE-DOY", "SE"), ("OY-KBO", "DK"), ("OH-LWA", "FI"),
            ("B-HNR", "HK"), ("B-KPA", "HK"), ("B-LRA", "HK"), ("B-MAC", "MO"),
            ("B-18901", "TW"), ("B-16701", "TW"), ("B-0001", "TW"), ("B-1234", "CN"), ("B-30AB", "CN"),
            ("VP-BJA", "BM"), ("VP-CAB", "KY"), ("ES-ACB", "EE"), ("ZZ-TOP", nil), ("", nil),
        ]
        for (reg, iso) in cases {
            #expect(AircraftStatsCopy.registrationCountry(reg) == iso, "\(reg)")
        }
    }

    @Test func typesTotalSingular() {
        #expect(AircraftStatsCopy.typesTotal(12) == ("12", " total aircraft"))
        #expect(AircraftStatsCopy.typesTotal(1) == ("1", " aircraft"))
    }

    /// The share image is dark even when the screen around the Share button is light.
    @MainActor @Test func shareImageIsDarkOnALightScreen() throws {
        let page = SectionShareButton<Text>.sharePage(title: "Aircraft types", units: Units(), reference: .bundled()) {
            Text("12 total aircraft")
        }
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixel = try #require(Self.pixel(image, x: 4, y: image.height - 4))
        #expect(pixel.r < 60 && pixel.g < 60 && pixel.b < 60, "background \(pixel)")
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}

/// The "9 flights · 42 hours" line meets WCAG AA (4.5:1) over the part of the page fade it can sit on: from
/// the second stop to a quarter past the third, toward the blueprint blue.
@Test func mostFlownHoursLineMeetsContrast() {
    func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { BrandArt.relativeLuminance(r: r, g: g, b: b) }
    let ink = lum(Blueprint.deepRGB.r, Blueprint.deepRGB.g, Blueprint.deepRGB.b)
    let second = (0xA6 / 255.0, 0xCA / 255.0, 0xF1 / 255.0), third = (0x55 / 255.0, 0x90 / 255.0, 0xCF / 255.0)
    let blueprint = (0x2F / 255.0, 0x6B / 255.0, 0xBA / 255.0)
    func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Double {
        lum(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
    for t in stride(from: 0.0, through: 1.0, by: 0.1) {
        #expect(BrandArt.contrast(ink, mix(second, third, t)) >= 4.5, "at \(t)")
    }
    #expect(BrandArt.contrast(ink, mix(third, blueprint, 0.25)) >= 4.5)
}
