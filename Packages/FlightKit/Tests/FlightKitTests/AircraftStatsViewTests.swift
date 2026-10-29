import Testing
import Foundation
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
        #expect(cls.centreTitle == "Top class" && cls.centreValue == "Economy")
        #expect(cls.slices.map(\.percent) == [96, 0, 4, 0])
        let seat = AircraftStatsCopy.seatDonut(some)
        #expect(seat.centreTitle == "Top seat" && seat.centreValue == "20D")
        #expect(seat.slices.map(\.label) == ["Aisle", "Middle", "Window"])
        #expect(seat.slices.map(\.percent) == [69, 17, 14])
        let reason = AircraftStatsCopy.reasonDonut(some)
        #expect(reason.centreTitle == "Top reason" && reason.centreValue == "Personal")
        #expect(reason.slices.map(\.percent) == [62, 38])
        #expect(AircraftStatsCopy.favouriteSeat(some)?.value == "20D (2 times)")

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
        #expect(noFacts.tailAgeMonths.isEmpty)

        let withFacts = PassportStore(history: FakeHistoryService(), facts: FakeAircraftFactsService(),
                                      asOf: Date(timeIntervalSince1970: 1_793_000_000))
        await withFacts.load()
        #expect(AircraftStatsCopy.showsAges(withFacts.aircraft))
        #expect(!AircraftStatsCopy.decadeLabels(withFacts.aircraft.decades).isEmpty)
        // The top tail's age comes from the core run on its own flights.
        let top = withFacts.aircraft.tails[0]
        #expect(withFacts.tailAgeMonths[top.registration] != nil)
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
        #expect(AircraftStatsCopy.registrationCountry("F-GSQI") == "FR")
        #expect(AircraftStatsCopy.registrationCountry("N370DN") == "US")
        #expect(AircraftStatsCopy.registrationCountry("G-ZBKD") == "GB")
        #expect(AircraftStatsCopy.registrationCountry("PH-BKL") == "NL")
        #expect(AircraftStatsCopy.registrationCountry("B-HNR") == "HK")
        #expect(AircraftStatsCopy.registrationCountry("B-1234") == "CN")
        #expect(AircraftStatsCopy.registrationCountry("JA873J") == "JP")
        #expect(AircraftStatsCopy.registrationCountry("ZZ-TOP") == nil)
    }
}
