import Foundation

/// The Delay Report's figures for one year (or all time). Pure: the same flights and year give the same
/// report.
///
/// Definitions:
/// - **Delayed** means the flight arrived after its scheduled arrival, by any minute: gate times when both
///   are known, else runway times (`PastFlight.arrivalDelayMinutes`, set by the import).
/// - **With times**: completed flights whose arrival delay is known. They are the denominator of every
///   arrival share. Completed flights without it are **no data** and left out of the shares; canceled and
///   diverted flights have their own buckets (their scheduled arrival never happened).
/// - **Lost**: the sum of the delayed flights' minutes late. **Net**: the sum of every timed flight's
///   minutes, early arrivals taking time back.
/// - **Buckets** keep the industry's 15 minute view: on time is up to 14 minutes late.
/// - **Late departures** compare the actual and scheduled departure (`departureDelayMinutes`), by the
///   origin airport.
public struct DelayReport: Equatable, Sendable {
    /// One flight that arrived late, and by how much.
    public struct Late: Equatable, Sendable, Identifiable {
        public var flight: PastFlight
        public var minutes: Int
        public var id: UUID { flight.id }
    }

    /// "10 of 13": a count over a total, for an airline, an airport or the whole report.
    public struct Share: Equatable, Sendable {
        public var late: Int
        public var of: Int
        /// 0 to 1; 0 with nothing counted.
        public var fraction: Double { of == 0 ? 0 : Double(late) / Double(of) }
        /// Whole percent, rounded half up.
        public var percent: Int { of == 0 ? 0 : (late * 200 + of) / (of * 2) }
    }

    /// An airline or airport row: its key (airline ICAO or code, airport ICAO), its share and, for an
    /// airport, its country.
    public struct Row: Equatable, Sendable, Identifiable {
        public var key: String
        public var share: Share
        public var country: String?
        public var id: String { key }
    }

    /// An airline's total minutes late, for the worst airline bar.
    public struct AirlineLoss: Equatable, Sendable, Identifiable {
        public var key: String
        public var minutes: Int
        public var flights: Int
        /// The aircraft type this airline flew late most often, for its tail art.
        public var type: String?
        public var id: String { key }
    }

    public enum Bucket: String, CaseIterable, Sendable {
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

        /// The bucket of a known arrival delay.
        static func of(_ minutes: Int) -> Bucket {
            switch minutes {
            case ..<0: .early
            case 0..<15: .onTime
            case 15..<30: .late15
            case 30..<45: .late30
            default: .late45
            }
        }
    }

    /// Every flight in the year.
    public var flights: Int
    /// Completed flights with a known arrival delay: the denominator of the arrival shares.
    public var withTimes: Int
    /// Completed flights without one.
    public var noData: Int
    public var canceled: Int
    public var diverted: Int
    /// Flights that arrived after schedule, over `withTimes`.
    public var lateArrivals: Share
    public var lostMinutes: Int
    /// Mean minutes late of the delayed flights, rounded half up; 0 when none.
    public var averageLateMinutes: Int
    /// Signed sum over every timed flight: positive means late overall.
    public var netMinutes: Int
    /// Count per bucket, every bucket present.
    public var buckets: [Bucket: Int]
    /// Every delayed flight, latest first (ties: newest first).
    public var arrivalDelays: [Late]
    /// Airlines by minutes late, most first; only airlines with a delayed flight.
    public var airlineLosses: [AirlineLoss]
    /// Late arrivals per airline, worst share first (ties: more flights, then key).
    public var airlines: [Row]
    /// Departures with a known delay that left late, over those known.
    public var lateDepartures: Share
    /// Late departures per origin airport, worst share first.
    public var airports: [Row]

    /// The worst delay of the year.
    public var worst: Late? { arrivalDelays.first }
    /// Flights in the buckets: those with times plus the canceled and diverted ones.
    public var bucketTotal: Int { withTimes + canceled + diverted }

    public func count(_ b: Bucket) -> Int { buckets[b] ?? 0 }

    /// The bucket's share of `bucketTotal`, 0 to 1.
    public func fraction(_ b: Bucket) -> Double {
        bucketTotal == 0 ? 0 : Double(count(b)) / Double(bucketTotal)
    }

    /// Whole percent of `bucketTotal`, rounded half up.
    public func percent(_ b: Bucket) -> Int {
        Share(late: count(b), of: bucketTotal).percent
    }

    public static let empty = DelayReport.compute([], year: nil)

    /// The arrival delay the report counts for a flight: the import's own field when set; else, for a
    /// completed flight, the older `delayMinutes` when it is not 0; else 0 for archived and hand added
    /// flights (the archive and the editor write 0 for on time) and nil for imported ones (imports
    /// before the field wrote 0 when the file had no arrival time). Canceled and diverted give nil.
    static func arrivalDelay(_ f: PastFlight) -> Int? {
        guard f.status == .completed else { return nil }
        if let m = f.arrivalDelayMinutes { return m }
        if f.delayMinutes != 0 { return f.delayMinutes }
        return f.source == .import ? nil : 0
    }

    /// The report over `flights` for `year` (local departure year at the origin; nil for all time).
    /// Airlines are keyed as given (the store maps them to ICAO first); a flight without one is keyed by
    /// the code its flight number starts with.
    public static func compute(_ flights: [PastFlight], year: Int?) -> DelayReport {
        let kept = flights.filter { year == nil || $0.localYear == year }
        var buckets = Dictionary(uniqueKeysWithValues: Bucket.allCases.map { ($0, 0) })
        var withTimes = 0, noData = 0, canceled = 0, diverted = 0, net = 0
        var lates: [Late] = []
        var airlineCounts: [String: Share] = [:]
        var losses: [String: (minutes: Int, flights: Int, types: [String: Int])] = [:]
        var airportCounts: [String: Share] = [:]
        var countries: [String: String] = [:]
        var departures = Share(late: 0, of: 0)

        for f in kept {
            switch f.status {
            case .canceled: canceled += 1; buckets[.canceled, default: 0] += 1
            case .diverted: diverted += 1; buckets[.diverted, default: 0] += 1
            case .completed:
                if let m = arrivalDelay(f) {
                    withTimes += 1
                    net += m
                    buckets[Bucket.of(m), default: 0] += 1
                    let key = airlineKey(f)
                    var share = airlineCounts[key] ?? Share(late: 0, of: 0)
                    share.of += 1
                    if m > 0 {
                        share.late += 1
                        lates.append(Late(flight: f, minutes: m))
                        var loss = losses[key] ?? (0, 0, [:])
                        loss.minutes += m
                        loss.flights += 1
                        if let t = f.aircraftType, !t.isEmpty { loss.types[t.uppercased(), default: 0] += 1 }
                        losses[key] = loss
                    }
                    airlineCounts[key] = share
                } else {
                    noData += 1
                }
            }
            // A canceled flight never left; a diverted one did, on its own schedule.
            if f.status != .canceled, let d = f.departureDelayMinutes {
                let key = f.originIcao.uppercased()
                var share = airportCounts[key] ?? Share(late: 0, of: 0)
                share.of += 1
                departures.of += 1
                if d > 0 { share.late += 1; departures.late += 1 }
                airportCounts[key] = share
                if let c = f.originCountry { countries[key] = c }
            }
        }

        lates.sort { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.flight.date > $1.flight.date }
        let lost = lates.reduce(0) { $0 + $1.minutes }
        let n = lates.count
        func rows(_ counts: [String: Share], country: (String) -> String? = { _ in nil }) -> [Row] {
            counts.map { Row(key: $0.key, share: $0.value, country: country($0.key)) }
                .sorted {
                    if $0.share.late * $1.share.of != $1.share.late * $0.share.of {
                        return $0.share.late * $1.share.of > $1.share.late * $0.share.of
                    }
                    return $0.share.of != $1.share.of ? $0.share.of > $1.share.of : $0.key < $1.key
                }
        }
        return DelayReport(
            flights: kept.count, withTimes: withTimes, noData: noData, canceled: canceled, diverted: diverted,
            lateArrivals: Share(late: n, of: withTimes), lostMinutes: lost,
            averageLateMinutes: n == 0 ? 0 : (2 * lost + n) / (2 * n), netMinutes: net, buckets: buckets,
            arrivalDelays: lates,
            airlineLosses: losses.map { key, v in
                AirlineLoss(key: key, minutes: v.minutes, flights: v.flights,
                            type: v.types.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key)
            }
            .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.key < $1.key },
            airlines: rows(airlineCounts), lateDepartures: departures,
            airports: rows(airportCounts) { countries[$0] })
    }

    /// The airline a flight counts under: its airline, else the code its flight number starts with.
    static func airlineKey(_ f: PastFlight) -> String {
        if let a = f.airline?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a.uppercased() }
        return TravelFacts.airlineCode(ident: f.ident)
    }
}
