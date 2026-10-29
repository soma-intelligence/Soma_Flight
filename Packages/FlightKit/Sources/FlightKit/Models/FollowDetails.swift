import Foundation

public enum SeatClass: String, Codable, Sendable, CaseIterable {
    case economy
    case premiumEconomy = "premium_economy"
    case business
    case first

    public var title: String {
        switch self {
        case .economy: "Economy"
        case .premiumEconomy: "Premium Economy"
        case .business: "Business"
        case .first: "First"
        }
    }
}

public enum TripReason: String, Codable, Sendable, CaseIterable {
    case personal, business

    public var title: String {
        switch self {
        case .personal: "Personal"
        case .business: "Business"
        }
    }
}

/// What the traveller notes on a followed flight: the five `user_flights` fields they can write.
public struct FollowDetails: Codable, Sendable, Hashable {
    public var seatClass: SeatClass?
    public var seat: String?
    public var reason: TripReason?
    public var bookingCode: String?
    public var notes: String?

    public init(seatClass: SeatClass? = nil, seat: String? = nil, reason: TripReason? = nil,
                bookingCode: String? = nil, notes: String? = nil) {
        self.seatClass = seatClass; self.seat = seat; self.reason = reason
        self.bookingCode = bookingCode; self.notes = notes
    }

    public static let empty = FollowDetails()

    public static let maxNotes = 2000

    /// Trimmed, upper-cased seat. `.some(nil)` for empty input (clear the field), nil when it is not a
    /// seat ("12A": one to three digits and a letter A to K).
    public static func normalizedSeat(_ s: String) -> String?? {
        normalized(s, pattern: /[0-9]{1,3}[A-K]/)
    }

    /// Trimmed, upper-cased booking code of five to eight letters and digits. `.some(nil)` for empty
    /// input, nil when invalid.
    public static func normalizedBookingCode(_ s: String) -> String?? {
        normalized(s, pattern: /[A-Z0-9]{5,8}/)
    }

    /// Trimmed notes, nil when empty or longer than 2000 characters. Characters are Unicode scalars, as
    /// Postgres `char_length` counts them (a family emoji is 5 scalars, not 1).
    public static func normalizedNotes(_ s: String) -> String?? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .some(nil) }
        return t.unicodeScalars.count <= maxNotes ? .some(t) : nil
    }

    private static func normalized(_ s: String, pattern: Regex<Substring>) -> String?? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.isEmpty { return .some(nil) }
        return t.wholeMatch(of: pattern) != nil ? .some(t) : nil
    }
}
