import Foundation
import Synchronization
import Testing
@testable import FlightKit

/// Task 18: the My Flights row's countdown column, its date and times, and the follow toast.
private func date(_ s: String) -> Date { try! Date(s, strategy: .iso8601) }

@MainActor @Suite struct MyFlightRowTests {
    /// UA 990, SFO 15:20 Friday 30 October 2026 to CDG 10:15 the next morning.
    static var ua990: Flight {
        Flight(providerId: "p", ident: "UA990", operator: "UAL", originIcao: "KSFO", originIata: "SFO",
               destinationIcao: "LFPG", destinationIata: "CDG",
               scheduledOut: date("2026-10-30T22:20:00Z"), scheduledIn: date("2026-10-31T09:15:00Z"),
               status: .scheduled)
    }

    @Test func countdownColumnCases() {
        let f = Self.ua990
        let out = f.scheduledOut!, arr = f.scheduledIn!
        func col(_ f: Flight, _ now: Date) -> String {
            let c = DetailFacts.countdownColumn(f, now: now)
            return "\(c.value)|\(c.unit)"
        }
        #expect(col(f, out.addingTimeInterval(-86_400)) == "1|DAY")
        #expect(col(f, out.addingTimeInterval(-47 * 3600)) == "1|DAY")
        #expect(col(f, out.addingTimeInterval(-3 * 86_400 - 60)) == "3|DAYS")
        #expect(col(f, out.addingTimeInterval(-5 * 3600 - 59)) == "5|HRS")
        #expect(col(f, out.addingTimeInterval(-3600)) == "1|HR")
        #expect(col(f, out.addingTimeInterval(-40 * 60 - 10)) == "40|MIN")
        #expect(col(f, out.addingTimeInterval(-90)) == "1|MIN")
        #expect(col(f, out.addingTimeInterval(30)) == "|DEPARTING")
        var unknownOut = f
        unknownOut.scheduledOut = nil
        #expect(col(unknownOut, out) == "|SCHEDULED")

        var air = f
        air.status = .enRoute
        air.actualOut = out
        #expect(col(air, arr.addingTimeInterval(-2 * 3600 - 300)) == "2h|LEFT")
        #expect(col(air, arr.addingTimeInterval(-40 * 60)) == "40m|LEFT")
        #expect(col(air, arr.addingTimeInterval(60)) == "|ARRIVING")
        var unknownIn = air
        unknownIn.scheduledIn = nil
        #expect(col(unknownIn, out) == "|IN AIR")

        for (status, word) in [(FlightStatus.landed, "LANDED"), (.arrived, "LANDED"), (.canceled, "CANCELED"),
                               (.diverted, "DIVERTED")] {
            var g = f
            g.status = status
            #expect(col(g, out) == "|\(word)")
        }
    }

    @Test func rowDateAndTimes() {
        let f = Self.ua990
        let sfo = DetailPart1Tests.sfo, cdg = DetailPart1Tests.cdg
        #expect(MyFlightRow.day(f, origin: sfo) == "Fri, Oct 30")
        #expect(MyFlightRow.marker(f, origin: sfo, destination: cdg) == "+1")
        // A delay past local midnight moves the date with the time shown.
        var late = f
        late.estimatedOut = date("2026-10-31T08:30:00Z")
        #expect(MyFlightRow.day(late, origin: sfo) == "Sat, Oct 31")
        var short = f
        short.scheduledIn = f.scheduledOut!.addingTimeInterval(2 * 3600)
        #expect(MyFlightRow.marker(short, origin: sfo, destination: sfo) == nil)
    }

    @Test func toastClearsAfterThreeSeconds() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake())
        let (gate, open) = AsyncStream<Void>.makeStream()
        let asked = Mutex<[Duration]>([])
        home.toastSleep = { d in
            asked.withLock { $0.append(d) }
            for await _ in gate { return }
        }
        await home.didFollow(Self.ua990)
        #expect(home.toast == "Following UA 990")
        // The clock has not moved: the toast stays.
        for _ in 0..<20 { await Task.yield() }
        #expect(home.toast == "Following UA 990")
        open.yield()
        for _ in 0..<1000 where home.toast != nil { await Task.yield() }
        #expect(home.toast == nil)
        #expect(asked.withLock { $0 } == [.seconds(3)])
    }

    /// iOS: a follow inside the search sheet keeps its toast until the sheet closes, then shows it in full.
    @Test func toastWaitsForTheSearchSheet() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake())
        let (gate, open) = AsyncStream<Void>.makeStream()
        let asked = Mutex(0)
        home.toastSleep = { _ in
            asked.withLock { $0 += 1 }
            for await _ in gate { return }
        }
        home.searchOpen = true
        await home.didFollow(Self.ua990)
        #expect(home.toast == nil)
        #expect(home.pendingToast == "Following UA 990")
        for _ in 0..<20 { await Task.yield() }
        #expect(asked.withLock { $0 } == 0)
        home.searchOpen = false
        #expect(home.toast == "Following UA 990")
        #expect(home.pendingToast == nil)
        open.yield()
        for _ in 0..<1000 where home.toast != nil { await Task.yield() }
        #expect(home.toast == nil)
        #expect(asked.withLock { $0 } == 1)
    }

    /// Frequently used reads every year of the history, not the year the Passport shows.
    @Test func frequentIgnoresThePassportYear() async throws {
        let home = HomeModel(env: try await AppEnvironment.fake())
        await home.load()
        let years = home.passport.years
        #expect(years.count > 1)
        let all = home.frequent
        #expect(!all.isEmpty)
        for y in years {
            home.passport.year = y
            #expect(home.frequent == all)
        }
    }
}
