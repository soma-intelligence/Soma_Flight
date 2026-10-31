import Foundation

/// Where a past arrival of a flight number landed against its schedule. Early is before the schedule,
/// on time 0 to 14 minutes after, then 15 to 29, 30 to 44, 45 or more.
public enum ForecastBucket: String, CaseIterable, Sendable {
    case early, onTime, late15, late30, late45, canceled, diverted

    public var title: String {
        switch self {
        case .early: "Early"
        case .onTime: "On time"
        case .late15: "15m late"
        case .late30: "30m late"
        case .late45: "45m+ late"
        case .canceled: "Canceled"
        case .diverted: "Diverted"
        }
    }

    /// The bucket of an arrival `minutes` after its schedule (negative is early).
    public static func of(lateMinutes minutes: Int) -> ForecastBucket {
        switch minutes {
        case ..<0: .early
        case 0..<15: .onTime
        case 15..<30: .late15
        case 30..<45: .late30
        default: .late45
        }
    }
}

/// How a flight number arrived over the last `days`: paid data (AeroAPI history through
/// `flight-insights`), or the fakes in screenshot runs.
public struct ArrivalForecast: Sendable, Hashable {
    public var ident: String
    public var days: Int
    /// Flights seen in the window.
    public var observed: Int
    /// Share that arrived 15 minutes late or more.
    public var latePercent: Int
    /// Average delay of the late ones.
    public var averageLateMinutes: Int
    /// Every bucket, summing to 100.
    public var percents: [ForecastBucket: Int]

    public init(ident: String, days: Int, observed: Int, latePercent: Int, averageLateMinutes: Int,
                percents: [ForecastBucket: Int]) {
        self.ident = ident; self.days = days; self.observed = observed; self.latePercent = latePercent
        self.averageLateMinutes = averageLateMinutes; self.percents = percents
    }
}

/// One earlier flight of the aircraft that will fly this one (paid data through `flight-insights`, or the
/// fakes in screenshot runs).
public struct InboundLeg: Sendable, Hashable, Identifiable {
    public var id: String
    public var ident: String
    public var originIata: String
    public var destinationIata: String
    public var scheduledOut: Date
    public var scheduledIn: Date
    public var status: FlightStatus
    public var delayMinutes: Int

    public init(id: String, ident: String, originIata: String, destinationIata: String, scheduledOut: Date,
                scheduledIn: Date, status: FlightStatus, delayMinutes: Int) {
        self.id = id; self.ident = ident; self.originIata = originIata; self.destinationIata = destinationIata
        self.scheduledOut = scheduledOut; self.scheduledIn = scheduledIn; self.status = status
        self.delayMinutes = delayMinutes
    }
}
