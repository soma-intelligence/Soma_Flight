import Foundation
import Testing
@testable import FlightKit

/// Plan 18: the figures behind the Year in Review cards, worked out on the device.
@Suite struct YearInReviewTests {
    /// 2025-03-10 08:00 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_741_593_600)
    static func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }
    /// Mid 2025 and mid 2026, for "so far".
    static let in2025 = Date(timeIntervalSince1970: 1_751_328_000)
    static let in2026 = Date(timeIntervalSince1970: 1_782_864_000)

    static func leg(_ from: String, _ to: String, day n: Double, airline: String = "AFR", ident: String = "AF84",
                    km: Int, block: Int? = 120, type: String? = "A359", arrival: Int? = nil,
                    status: PastFlightStatus = .completed) -> PastFlight {
        PastFlight(date: day(n), ident: ident, originIcao: from, destinationIcao: to, airline: airline,
                   aircraftType: type, distanceKm: km, blockMinutes: block, status: status, originTz: "UTC",
                   arrivalDelayMinutes: arrival)
    }

    static let year2025: [PastFlight] = [
        leg("KSFO", "LFPG", day: 0, km: 8_950, block: 640, arrival: 30),
        leg("LFPG", "KSFO", day: 10, km: 8_950, block: 680, arrival: -5),
        leg("KSFO", "KJFK", day: 40, airline: "UAL", ident: "UA1", km: 4_150, block: 330, type: "B77W", arrival: 0),
        leg("KJFK", "KSFO", day: 44, airline: "UAL", ident: "UA2", km: 4_150, block: 380, type: "B77W", arrival: 12),
        leg("KSFO", "LFPG", day: 80, km: 8_950, block: 650, arrival: 0),
        leg("KSFO", "RJTT", day: 120, airline: "ANA", ident: "NH7", km: 8_270, block: 660, arrival: nil,
            status: .canceled),
    ]

    @Test func aggregatesTheYear() throws {
        let r = try #require(YearInReview.make(Self.year2025, year: 2025, now: Self.in2026, timeZone: .gmt))
        #expect(r.flights == 5)
        #expect(r.distanceKm == 35_150)
        #expect(abs(r.earthLaps - 35_150.0 / 40_075.0) < 0.01)
        #expect(r.flightMinutes == 640 + 680 + 330 + 380 + 650)
        #expect(Set(r.countries) == ["US", "FR"])
        #expect(Set(r.airports) == ["KSFO", "LFPG", "KJFK"])
        #expect(r.airports.first == "KSFO")
        #expect(r.longest?.distanceKm == 8_950)
        #expect(r.delayLostMinutes == 42)
        #expect(r.timedFlights == 5)
        #expect(r.topRoute == .init(originIcao: "KSFO", destinationIcao: "LFPG", flights: 2))
        #expect(r.topAircraft?.type == "A359")
        #expect(r.topAircraft?.flights == 3)
        #expect(!r.isSoFar)
        #expect(r.cards == YearInReview.Card.allCases)
    }

    @Test func mostPunctualAirline() throws {
        let r = try #require(YearInReview.make(Self.year2025, year: 2025, now: Self.in2026, timeZone: .gmt))
        // Air France: 1 late of 3 (67% on time); United: 1 late of 2 (50%).
        #expect(r.punctual == .init(airline: "AFR", onTimePercent: 67, flights: 3))
    }

    @Test func oneAirlineMakesNoPunctualPick() throws {
        let flights = Self.year2025.filter { $0.airline == "AFR" }
        let r = try #require(YearInReview.make(flights, year: 2025, now: Self.in2026, timeZone: .gmt))
        #expect(r.punctual == nil)
    }

    @Test func currentYearIsSoFar() throws {
        let r = try #require(YearInReview.make(Self.year2025, year: 2025, now: Self.in2025, timeZone: .gmt))
        #expect(r.isSoFar)
        #expect(YearInReviewFacts.kicker(r) == "2025 so far")
        #expect(YearInReviewFacts.entry(year: 2025, soFar: true) == "2025 So Far")
        #expect(YearInReviewFacts.entry(year: 2024, soFar: false) == "2024 in Review")
    }

    @Test func emptyYearIsHidden() {
        #expect(YearInReview.make(Self.year2025, year: 2024, now: Self.in2026) == nil)
        #expect(YearInReview.make([], year: 2025, now: Self.in2026) == nil)
        // Canceled flights alone make no review and no year.
        let canceled = Self.year2025.filter { $0.status == .canceled }
        #expect(YearInReview.make(canceled, year: 2025, now: Self.in2026) == nil)
        #expect(YearInReview.years(canceled).isEmpty)
        #expect(YearInReview.years(Self.year2025) == [2025])
    }

    @Test func cardsWithNothingToSayAreLeftOut() throws {
        // An imported flight without arrival times has no known delay.
        var flight = Self.leg("KSFO", "KLAX", day: 0, km: 540, block: nil, type: nil, arrival: nil)
        flight.source = .import
        let one = [flight]
        let r = try #require(YearInReview.make(one, year: 2025, now: Self.in2026, timeZone: .gmt))
        #expect(!r.cards.contains(.delays))
        #expect(!r.cards.contains(.favorite))
        #expect(r.cards.contains(.flights))
    }

    @Test func copy() {
        #expect(YearInReviewFacts.laps(1.7) == "1.7 times around the Earth")
        #expect(YearInReviewFacts.laps(1.0) == "Once around the Earth")
        #expect(YearInReviewFacts.time(7_260) == ("121", "hours in the air"))
        #expect(YearInReviewFacts.time(90).caption == "minutes in the air")
        #expect(YearInReviewFacts.lost(252).value == "4h 12m")
        let all = [YearInReviewFacts.laps(0.01), YearInReviewFacts.days(10_000) ?? "", YearInReviewFacts.longHauls(3) ?? "",
                   YearInReviewFacts.timed(4), YearInReviewFacts.punctual(.init(airline: "AFR", onTimePercent: 90, flights: 9))]
        #expect(all.allSatisfy { !$0.contains("\u{2014}") })
    }

    @MainActor @Test func eachCardRendersAtStorySize() throws {
        let r = try #require(YearInReview.make(Self.year2025, year: 2025, now: Self.in2026, timeZone: .gmt))
        for card in r.cards {
            let image = try #require(YearInReviewRender.image(card, review: r, unit: .km), "\(card)")
            #expect(image.width == 1_080, "\(card)")
            #expect(image.height == 1_920, "\(card)")
            let png = try #require(YearInReviewRender.png(image))
            #expect(png.count > 1_000)
        }
    }
}
