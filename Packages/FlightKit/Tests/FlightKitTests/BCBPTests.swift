import Foundation
import Testing
@testable import FlightKit

@Suite struct BCBPTests {
    /// Resolution 792's own sample: one leg, mandatory items only.
    static let single = "M1DESMARAIS/LUC       EABC123 YULFRAAC 0834 326J001A0025 100"
    /// Two legs with the shared conditional items, each leg's own items, airline data and security data.
    static let twoLegs = "M2DESMARAIS/LUC MR    EABC123 YULFRAAC 0834 326J001A0025 13F>60B1WW6295BAC 2A014123456789000AC AC 1234567890123    2PCYGRP2DEF456 FRAGVALH 3664A327C012C0002 12C2A014098765432100LH                     1PCN^108ABCDEFGH"

    @Test func singleLegMandatoryItems() throws {
        let p = try BCBP.parse(Self.single)
        #expect(p.formatCode == "M")
        #expect(p.passengerName == "DESMARAIS/LUC")
        #expect(p.electronicTicket)
        #expect(p.legs.count == 1)
        let leg = try #require(p.legs.first)
        #expect(leg.pnr == "ABC123")
        #expect(leg.from == "YUL")
        #expect(leg.to == "FRA")
        #expect(leg.carrier == "AC")
        #expect(leg.flightNumber == "834")
        #expect(leg.dayOfYear == 326)
        #expect(leg.compartment == "J")
        #expect(leg.seat == "1A")
        #expect(leg.sequence == "25")
        #expect(leg.passengerStatus == "1")
        #expect(leg.marketingCarrier == nil)
        #expect(p.version == nil)
        #expect(p.issueYearDigit == nil)
        #expect(p.securityData == nil)
    }

    @Test func multiLegWithConditionalItems() throws {
        let p = try BCBP.parse(Self.twoLegs)
        #expect(p.legs.count == 2)
        #expect(p.version == 6)
        #expect(p.issueYearDigit == 6)
        #expect(p.issueDayOfYear == 295)
        #expect(p.issuingAirline == "AC")
        #expect(p.securityData == "ABCDEFGH")
        let first = p.legs[0]
        #expect(first.airlineNumericCode == "014")
        #expect(first.documentNumber == "1234567890")
        #expect(first.marketingCarrier == "AC")
        #expect(first.frequentFlyerAirline == "AC")
        #expect(first.frequentFlyerNumber == "1234567890123")
        #expect(first.baggageAllowance == "2PC")
        #expect(first.fastTrack == true)
        #expect(first.airlineData == "GRP2")
        let second = p.legs[1]
        #expect(second.pnr == "DEF456")
        #expect(second.from == "FRA")
        #expect(second.to == "GVA")
        #expect(second.carrier == "LH")
        #expect(second.flightNumber == "3664A")
        #expect(second.dayOfYear == 327)
        #expect(second.seat == "12C")
        #expect(second.sequence == "2")
        #expect(second.marketingCarrier == "LH")
        #expect(second.frequentFlyerAirline == nil)
        #expect(second.fastTrack == false)
        #expect(second.airlineData == nil)
    }

    @Test func conditionalBlockThatEndsEarlyKeepsWhatItHolds() throws {
        // The variable block says 0x3F characters but the string stops right after the issue date.
        let cut = "M1" + String(Self.twoLegs.dropFirst(2).prefix(69))
        let p = try BCBP.parse(cut)
        #expect(p.issueYearDigit == 6)
        #expect(p.issueDayOfYear == 295)
        #expect(p.issuingAirline == nil)
        #expect(p.legs.count == 1)
        #expect(p.legs[0].documentNumber == nil)
    }

    @Test func declaredLegThatIsMissingThrows() {
        // M2 declared, but the string holds one leg: the second leg's mandatory items are missing.
        #expect(throws: BCBP.ParseError.tooShort(field: "PNR code")) {
            try BCBP.parse("M2" + Self.single.dropFirst(2))
        }
    }

    @Test func shortFieldsArePaddedNotShifted() throws {
        // A two letter airline, a one digit flight, a two digit seat and blank sequence and compartment.
        let s = BCBP.encode(passengerName: "LI/WEI", pnr: "XY9Z7", from: "SFO", to: "LAX", carrier: "B6",
                            flightNumber: "7", dayOfYear: 5, compartment: " ", seat: "9F", sequence: 3)
        let leg = try #require(try BCBP.parse(s).legs.first)
        #expect(leg.carrier == "B6")
        #expect(leg.flightNumber == "7")
        #expect(leg.dayOfYear == 5)
        #expect(leg.seat == "9F")
        #expect(leg.sequence == "3")
        #expect(leg.compartment == nil)
        #expect(leg.pnr == "XY9Z7")
    }

    @Test func seatWordsStay() throws {
        let s = Self.single.replacingOccurrences(of: "001A0025", with: "INF 0025")
        #expect(try BCBP.parse(s).legs[0].seat == "INF")
        let blank = Self.single.replacingOccurrences(of: "001A0025 ", with: "         ")
        let leg = try BCBP.parse(blank).legs[0]
        #expect(leg.seat == nil)
        #expect(leg.sequence == nil)
    }

    @Test func badInput() {
        #expect(throws: BCBP.ParseError.notBoardingPass) { try BCBP.parse("https://example.com") }
        #expect(throws: BCBP.ParseError.notBoardingPass) { try BCBP.parse("") }
        #expect(throws: BCBP.ParseError.badField("number of legs")) { try BCBP.parse("MXDESMARAIS") }
        #expect(throws: BCBP.ParseError.badField("number of legs")) { try BCBP.parse("M5" + Self.single.dropFirst(2)) }
        #expect(throws: BCBP.ParseError.tooShort(field: "passenger name")) { try BCBP.parse("M1DESMARAIS") }
        #expect(throws: BCBP.ParseError.tooShort(field: "seat number")) { try BCBP.parse(String(Self.single.prefix(48))) }
        #expect(throws: BCBP.ParseError.tooShort(field: "field size of variable size field")) {
            try BCBP.parse(String(Self.single.prefix(58)))
        }
        #expect(throws: BCBP.ParseError.badField("from city airport code")) {
            try BCBP.parse(Self.single.replacingOccurrences(of: "YULFRA", with: "Y1LFRA"))
        }
        #expect(throws: BCBP.ParseError.badField("flight number")) {
            try BCBP.parse(Self.single.replacingOccurrences(of: "0834 ", with: "ABCDE"))
        }
        #expect(throws: BCBP.ParseError.badField("date of flight")) {
            try BCBP.parse(Self.single.replacingOccurrences(of: "326J", with: "400J"))
        }
        #expect(throws: BCBP.ParseError.badField("date of flight")) {
            try BCBP.parse(Self.single.replacingOccurrences(of: "326J", with: "ABCJ"))
        }
        #expect(throws: BCBP.ParseError.badField("field size of variable size field")) {
            try BCBP.parse(String(Self.single.dropLast(2)) + "ZZ")
        }
        #expect(throws: BCBP.ParseError.badField("passenger name")) {
            try BCBP.parse("M1" + String(repeating: " ", count: 20) + Self.single.dropFirst(22))
        }
    }

    @Test func trailingNewlineFromAScannerIsIgnored() throws {
        #expect(try BCBP.parse(Self.single + "\n").legs.count == 1)
    }

    @Test func dayPicksTheNearestYear() {
        // Day 326 is 22 November in 2025 (not a leap year).
        let near = Date(timeIntervalSince1970: 1_763_000_000) // 2025-11-13
        let leg = BCBP.Leg(pnr: "", from: "YUL", to: "FRA", carrier: "AC", flightNumber: "834", dayOfYear: 326)
        let day = leg.day(near: near)
        #expect(day?.year == 2025 && day?.month == 11 && day?.day == 22)
        // In early January, day 360 is last December's.
        let jan = Date(timeIntervalSince1970: 1_767_400_000) // 2026-01-03
        let late = BCBP.Leg(pnr: "", from: "YUL", to: "FRA", carrier: "AC", flightNumber: "834", dayOfYear: 360)
        #expect(late.day(near: jan)?.year == 2025)
        // Day 366 only exists in leap years, and 2025 to 2027 have none.
        let leap = BCBP.Leg(pnr: "", from: "YUL", to: "FRA", carrier: "AC", flightNumber: "834", dayOfYear: 366)
        #expect(leap.day(near: jan) == nil)
    }

    @Test func dayUsesTheIssueDate() throws {
        let p = try BCBP.parse(Self.twoLegs)
        // Issued on day 295 of a year ending in 6: 2026, so day 326 is 22 November 2026, even read years later.
        let later = Date(timeIntervalSince1970: 1_830_000_000) // 2027-12-27
        let day = p.day(of: p.legs[0], near: later)
        #expect(day?.year == 2026 && day?.month == 11 && day?.day == 22)
    }

    @Test func dayAfterAnIssueLateInTheYearRollsOver() {
        // Issued 30 December 2025 (digit 5, day 364) for a flight on day 2: 2 January 2026.
        let near = Date(timeIntervalSince1970: 1_767_000_000)
        let day = BCBP.day(of: 2, near: near, timeZone: .gmt, issue: (5, 364))
        #expect(day?.year == 2026 && day?.month == 1 && day?.day == 2)
    }

    @Test func encodeRoundTrips() throws {
        let s = BCBP.encode(passengerName: "DESMARAIS/LUC", pnr: "K7PQ2X", from: "CDG", to: "SFO", carrier: "AF",
                            flightNumber: "84", dayOfYear: 296, compartment: "J", seat: "23A", sequence: 12,
                            issueYearDigit: 6, issueDayOfYear: 295, baggageAllowance: "2PC", airlineData: "G2")
        let p = try BCBP.parse(s)
        #expect(p.passengerName == "DESMARAIS/LUC")
        #expect(p.issueYearDigit == 6 && p.issueDayOfYear == 295)
        #expect(p.issuingAirline == "AF")
        let leg = try #require(p.legs.first)
        #expect([leg.pnr, leg.from, leg.to, leg.carrier, leg.flightNumber] == ["K7PQ2X", "CDG", "SFO", "AF", "84"])
        #expect(leg.dayOfYear == 296)
        #expect(leg.seat == "23A")
        #expect(leg.sequence == "12")
        #expect(leg.baggageAllowance == "2PC")
        #expect(leg.marketingCarrier == "AF")
        #expect(leg.airlineData == "G2")
    }

    @Test func displayName() {
        #expect(BoardingPass.displayName("DESMARAIS/LUC") == "Luc Desmarais")
        #expect(BoardingPass.displayName("DESMARAIS/LUC MR") == "Luc Desmarais")
        #expect(BoardingPass.displayName("VAN DER BERG/ANNA MARIA MRS") == "Anna Maria Van Der Berg")
        #expect(BoardingPass.displayName("SMITH") == "Smith")
    }

    @Test func passFromBCBP() throws {
        let p = try BCBP.parse(Self.twoLegs)
        let near = Date(timeIntervalSince1970: 1_763_000_000)
        let pass = BoardingPass(bcbp: p, leg: 1, barcode: PassBarcode(message: Self.twoLegs, format: .pdf417), near: near)
        #expect(pass.source == .scan)
        #expect(pass.passenger == "Luc Desmarais")
        #expect(pass.ident == "LH3664A")
        #expect(pass.origin == "FRA" && pass.destination == "GVA")
        #expect(pass.seat == "12C")
        #expect(pass.bookingReference == "DEF456")
        #expect(pass.cabinTitle == "Business")
        #expect(pass.departureDay?.month == 11 && pass.departureDay?.day == 23)
    }
}
