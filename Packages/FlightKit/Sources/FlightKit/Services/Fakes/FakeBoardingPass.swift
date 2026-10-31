import Foundation

/// The boarding pass the fakes keep on AF 84 (the seed's first followed flight), so screenshot runs show
/// the Boarding Pass card and the full pass. Its barcode is a valid BCBP string built for the flight's day,
/// shifted like the rest of the seed. It poses as a Wallet pass with no file: `simulatesWallet` lets the
/// Add to Apple Wallet button show without a signed pass.
public enum FakeBoardingPass {
    /// AF 84 in the followed seed.
    public static let flightId = UUID(uuidString: "6f1c7d7e-3b0a-4f2e-9d55-2f6a1c0b8a11")!

    public static func af84(now: Date = .now) -> BoardingPass {
        let shift = FakeSeed.shift(now: now)
        // 13:10 in Paris on the seed's day; boarding opens 50 minutes before.
        let departs = Date(timeIntervalSince1970: 1_792_753_800).addingTimeInterval(shift) // 2026-10-23T11:10Z
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        let doy = cal.ordinality(of: .day, in: .year, for: departs) ?? 296
        let year = cal.component(.year, from: departs)
        let issued = cal.ordinality(of: .day, in: .year, for: departs.addingTimeInterval(-86_400)) ?? doy
        let message = BCBP.encode(passengerName: "LAURENT/CAMILLE", pnr: "K7PQ2X", from: "CDG", to: "SFO", carrier: "AF",
                                  flightNumber: "84", dayOfYear: doy, compartment: "J", seat: "6A", sequence: 41,
                                  issueYearDigit: year % 10, issueDayOfYear: issued, baggageAllowance: "2PC")
        return BoardingPass(
            id: UUID(uuidString: "0b0a5500-84af-4c0d-9e11-000000000084")!, flightId: flightId, source: .wallet,
            passenger: "Camille Laurent", carrier: "AF", flightNumber: "84", origin: "CDG", destination: "SFO",
            departureDay: cal.dateComponents([.year, .month, .day], from: departs), seat: "6A", compartment: "J",
            cabin: "Business", zone: "1", boardingTime: departs.addingTimeInterval(-50 * 60), gate: "B22",
            terminal: "2E", bookingReference: "K7PQ2X", sequence: "41", airlineName: "Air France",
            barcode: PassBarcode(message: message, format: .aztec, encoding: "iso-8859-1"),
            wallet: WalletPassID(passTypeIdentifier: "pass.me.somalabs.flight.sample", serialNumber: "AF84-K7PQ2X-6A"),
            addedAt: departs.addingTimeInterval(-86_400))
    }
}
