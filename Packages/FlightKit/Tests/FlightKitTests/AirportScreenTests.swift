import Foundation
import Testing
@testable import FlightKit

@MainActor
@Suite struct AirportScreenTests {
    let tz = PreviewData.kaus.timeZone
    let now = PreviewData.now

    /// The seed's stats were written by the Python reference; the Rust core must agree.
    @Test func coreStatsMatchSeed() {
        for code in ["KAUS", "KSFO"] {
            for (kind, departures) in [(BoardKind.departures, true), (.arrivals, false)] {
                let seed = PreviewData.stats(code, departures: departures)
                let core = DelayStats.compute(PreviewData.board(code, kind).flights, kind: kind)
                #expect(core.total == seed.total && core.onTime == seed.onTime)
                #expect(core.delayed15 == seed.delayed15 && core.canceled == seed.canceled)
                #expect(abs(core.avgDelayMinutes - seed.avgDelayMinutes) < 1e-6)
                #expect(core.perHour == seed.perHour)
                #expect(core.worstRoutes == seed.worstRoutes && core.worstAirlines == seed.worstAirlines)
                #expect(core.severity == seed.severity)
            }
        }
    }

    @Test func counts() {
        let dep = PreviewData.board("KAUS", .departures).flights
        let arr = PreviewData.board("KAUS", .arrivals).flights
        let c = AirportFacts.counts(departures: dep, arrivals: arr, lookup: PreviewData.airport)
        #expect(c.departures == dep.count)
        #expect(c.airlines == Set((dep + arr).compactMap(\.operator)).count)
        #expect(c.airportsServed == Set(dep.map(\.destinationIcao) + arr.map(\.originIcao)).count)
        #expect(c.countries == 3) // US, Mexico, Canada
        #expect(AirportFacts.country(icao: "MMMX") == "MX" && AirportFacts.country(icao: "CYYZ") == "CA")
        #expect(AirportFacts.flag("US") == "🇺🇸")
    }

    @Test func filtersAndNowDivider() {
        let flights = PreviewData.board("KAUS", .departures).flights
        let today = AirportFacts.calendar(tz).startOfDay(for: now)
        #expect(AirportFacts.days(flights, .departures, tz: tz) == [today])
        let all = AirportFacts.apply(.init(day: today), to: flights, kind: .departures, tz: tz)
        #expect(all.count == flights.count)
        #expect(zip(all, all.dropFirst()).allSatisfy { ($0.scheduledOut ?? .distantPast) <= ($1.scheduledOut ?? .distantPast) })
        let swa = AirportFacts.apply(.init(airline: "SWA"), to: flights, kind: .departures, tz: tz)
        #expect(!swa.isEmpty && swa.allSatisfy { $0.operator == "SWA" })
        let dfw = AirportFacts.apply(.init(place: "KDFW"), to: flights, kind: .departures, tz: tz)
        #expect(dfw.allSatisfy { $0.destinationIcao == "KDFW" })
        let index = AirportFacts.nowIndex(all, kind: .departures, now: now)
        #expect(index != nil)
        if let i = index {
            #expect(all[i].scheduledOut! >= now)
            if i > 0 { #expect(all[i - 1].scheduledOut! < now) }
        }
        let current = AirportFacts.current(all, kind: .departures, now: now)
        #expect(current.count < all.count)
        #expect(current.allSatisfy { (AirportFacts.best($0, .departures) ?? now) >= now.addingTimeInterval(-1800) })
    }

    @Test func issuesWording() {
        let s = PreviewData.stats("KAUS")
        #expect(AirportFacts.worst(.normal, .major) == .major && AirportFacts.worst(.moderate, .normal) == .moderate)
        let line = AirportFacts.delayLine(s, verb: "Leaving")
        #expect(line.hasPrefix("Leaving ") && line.contains("\(s.delayed15) of \(s.total)"))
        #expect(!line.contains("\u{2014}"))
        let w = AirportFacts.weatherLine(PreviewData.weather["KAUS"]!)
        #expect(w.contains("°C"))
    }
}
