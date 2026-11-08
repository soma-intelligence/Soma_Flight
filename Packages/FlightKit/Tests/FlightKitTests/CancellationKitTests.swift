import Foundation
@testable import FlightKit
import Testing

/// The cancellation kit: the bundled airline contacts are real airlines with dialable numbers and https
/// links, and the kit shows on a canceled flight or a delay of 3 hours or more at the gate.
@Suite struct CancellationKitTests {
    static let contacts = AirlineContacts.bundled
    static let departs = Date(timeIntervalSince1970: 1_800_000_000)

    static func flight(status: FlightStatus = .scheduled, lateMinutes: Int? = nil, actualOut: Date? = nil) -> Flight {
        Flight(providerId: "p", ident: "AF84", operator: "AFR", originIcao: "LFPG", destinationIcao: "KSFO",
               scheduledOut: departs, estimatedOut: lateMinutes.map { departs.addingTimeInterval(TimeInterval($0 * 60)) },
               actualOut: actualOut, status: status)
    }

    // MARK: Table

    @Test func everyEntryIsAKnownAirline() {
        let reference = ReferenceData.bundled()
        #expect(Self.contacts.airlines.count >= 30)
        for c in Self.contacts.airlines {
            let a = reference.airline(c.icao)
            #expect(a?.id == c.icao, "\(c.icao) is not in airlines.json")
            #expect(a?.iata == c.iata, "\(c.icao) IATA \(c.iata) differs from airlines.json")
        }
        #expect(Set(Self.contacts.airlines.map(\.icao)).count == Self.contacts.airlines.count)
    }

    @Test func numbersAreE164() {
        for c in Self.contacts.airlines {
            if let phone = c.phone {
                #expect(AirlineContact.isE164(phone), "\(c.icao) \(phone)")
                #expect(c.phoneURL?.scheme == "tel")
                #expect(c.phoneCountry?.count == 2)
            }
        }
        #expect(AirlineContact.isE164("+18004337300"))
        #expect(!AirlineContact.isE164("1-800-433-7300"))
        #expect(!AirlineContact.isE164("+0123456789"))
        #expect(!AirlineContact.isE164("+1234"))
    }

    @Test func linksAreHttpsAndEveryEntryIsSourcedAndDated() {
        for c in Self.contacts.airlines {
            #expect(c.rebook.scheme == "https", "\(c.icao) \(c.rebook)")
            #expect(c.source.scheme == "https", "\(c.icao) \(c.source)")
            #expect(c.checked.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, "\(c.icao) \(c.checked)")
        }
    }

    @Test func theDemoAirlinesAreCovered() {
        // The airlines of the followed and past fakes.
        for code in ["AFR", "UAL", "ASA", "DAL", "SWA", "AAL", "AMX", "ACA", "BAW", "JBU"] {
            #expect(Self.contacts.contact(code)?.phone != nil, "\(code)")
        }
        #expect(Self.contacts.contact("dl")?.icao == "DAL")
        #expect(Self.contacts.contact("XXX") == nil)
        #expect(Self.contacts.contact(nil) == nil)
    }

    // MARK: Trigger

    @Test func showsOnACancellation() {
        #expect(CancellationKit.isShown(Self.flight(status: .canceled)))
    }

    @Test func showsFromThreeHoursLateAtTheGate() {
        #expect(CancellationKit.isShown(Self.flight(lateMinutes: 180)))
        #expect(CancellationKit.isShown(Self.flight(lateMinutes: 300)))
        #expect(!CancellationKit.isShown(Self.flight(lateMinutes: 179)))
        #expect(!CancellationKit.isShown(Self.flight()))
    }

    @Test func hiddenOnceThePlaneLeftOrForOtherStates() {
        #expect(!CancellationKit.isShown(Self.flight(status: .enRoute, lateMinutes: 240)))
        #expect(!CancellationKit.isShown(Self.flight(lateMinutes: 240, actualOut: Self.departs.addingTimeInterval(14_400))))
        #expect(!CancellationKit.isShown(Self.flight(status: .diverted)))
        #expect(!CancellationKit.isShown(Self.flight(status: .landed, lateMinutes: 240)))
    }

    @Test func theDemoCancellationShowsTheKit() throws {
        let dl = try #require(FakeSeed.flights("followed", shift: 0).first { $0.ident == "DL2204" })
        #expect(CancellationKit.isShown(dl))
        #expect(Self.contacts.contact(dl.operator)?.name == "Delta Air Lines")
    }

    @Test func copyIsPlainAndHasTheChecklist() {
        #expect(CancellationKitFacts.title(Self.flight(status: .canceled)) == "Flight canceled: what to do")
        #expect(CancellationKitFacts.title(Self.flight(lateMinutes: 200)) == "Long delay: what to do")
        let joined = CancellationKitFacts.asks.joined(separator: " ")
        for word in ["next flight", "partner", "refund", "Meal", "hotel", "receipt"] {
            #expect(joined.contains(word), "\(word)")
        }
        #expect(CancellationKitFacts.call(Self.contacts.contact("AFR")!) == "Call Air France")
    }
}
