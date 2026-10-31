import Foundation

extension PastFlight {
    /// Typical airliner taxi times, for a past flight whose block time does not split into ground and air.
    static let taxiOutMinutes = 15
    static let taxiInMinutes = 8

    /// The flight as the detail sheet shows it, rebuilt from the history row: departed at `date`, the gate
    /// times `blockMinutes` apart, wheels off and on `airMinutes` apart inside them (65% of the ground time
    /// before take-off), and the schedule set back by `delayMinutes` at arrival. Canceled and diverted keep
    /// their status; everything else arrived.
    public var asFlight: Flight {
        let out = date
        let block = blockMinutes.map(Double.init)
        let air = airMinutes.map(Double.init) ?? block.map { max($0 - Double(Self.taxiOutMinutes + Self.taxiInMinutes), $0 * 0.6) }
        let ground = block.flatMap { b in air.map { max(b - $0, 0) } }
        let taxiOut = ground.map { $0 * 0.65 } ?? Double(Self.taxiOutMinutes)
        let flown = status != .canceled
        let actualIn = flown ? block.map { out.addingTimeInterval($0 * 60) } : nil
        let actualOff = flown ? air.map { _ in out.addingTimeInterval(taxiOut * 60) } : nil
        let actualOn = actualOff.flatMap { off in air.map { off.addingTimeInterval($0 * 60) } }
        let scheduledIn = actualIn.map { $0.addingTimeInterval(-Double(delayMinutes) * 60) }
        let flightStatus: FlightStatus = switch status {
        case .canceled: .canceled
        case .diverted: .diverted
        case .completed: .arrived
        }
        return Flight(id: id, providerId: "past-\(id.uuidString)", ident: ident, operator: airline,
                      originIcao: originIcao, destinationIcao: destinationIcao,
                      scheduledOut: out, scheduledIn: scheduledIn,
                      actualOut: flown ? out : nil, actualOff: actualOff, actualOn: actualOn, actualIn: actualIn,
                      aircraftType: aircraftType, registration: registration, status: flightStatus, updatedAt: date)
    }

    /// What the traveller noted on the flight, as the sheet's tiles read it.
    public var details: FollowDetails {
        FollowDetails(seatClass: seatClass, seat: seat, reason: reason, bookingCode: bookingCode, notes: notes,
                      seatPosition: seatPosition)
    }
}
