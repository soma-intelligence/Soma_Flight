import Foundation
import FlightCore

/// The flight sheet's two predictions, read by the Rust core (`predict.rs`) from what the sheet already
/// loaded: no call of their own beyond the gate history, and nothing paid. Views never import FlightCore;
/// they get FlightKit's `DelayPrediction` and `GatePrediction`.
public enum Predictions {
    /// The current observation speaks for a time this close to now; further out only a TAF period does.
    /// The backend reads its snapshots the same way (`prediction.ts`, METAR_HORIZON_MS).
    public static let metarHorizon: TimeInterval = 3 * 3600

    /// The likely departure delay of `flight`, or nil when the signals are weak, the flight has left or
    /// ended, or the airline's estimate already shows the delay.
    /// - Parameters:
    ///   - inbound: the aircraft's earlier legs, newest first (the first one brings the plane).
    ///   - forecast: how the flight number arrived lately.
    ///   - originStats: the origin's departures right now.
    ///   - originWeather, destinationWeather: each airport's weather snapshot.
    public static func delay(_ flight: Flight, inbound: [InboundLeg], forecast: ArrivalForecast?,
                             originStats: DelayStats?, originWeather: Weather?, destinationWeather: Weather?,
                             now: Date) -> DelayPrediction? {
        guard let scheduled = flight.scheduledOut else { return nil }
        let departure = flight.estimatedOut ?? scheduled
        let arrival = flight.estimatedIn ?? flight.scheduledIn
        let input = DelayInput(
            status: flight.status.core,
            scheduledOut: epoch(scheduled),
            estimatedOut: flight.estimatedOut.map(epoch),
            now: epoch(now),
            aircraftType: flight.aircraftType,
            originCode: flight.originIata ?? flight.originIcao,
            destinationCode: flight.destinationIata ?? flight.destinationIcao,
            inbound: inboundSignal(flight, inbound.first),
            history: forecast.map {
                HistorySignal(observed: u32($0.observed), latePercent: u32($0.latePercent),
                              averageLateMinutes: u32($0.averageLateMinutes))
            },
            board: originStats.map {
                BoardSignal(total: u32($0.total), delayed15: u32($0.delayed15), avgDelayMinutes: $0.avgDelayMinutes)
            },
            originWeather: weatherSignal(originWeather, at: departure, now: now),
            destinationWeather: weatherSignal(destinationWeather, at: arrival, now: now))
        return FlightCore.predictDelay(input: input).map(DelayPrediction.init)
    }

    /// The likely departure gate of `flight` from its gate history; nil once a real gate is known (it
    /// replaces the guess at once), for a flight that has left, or without a clear majority.
    public static func gate(_ flight: Flight, history: GateHistory?) -> GatePrediction? {
        guard flight.gateOrigin == nil, let history,
              flight.status == .scheduled || flight.status == .unknown else { return nil }
        let p = FlightCore.predictGate(
            days: history.days.map { GateDay(day: $0.day, gate: $0.gate, terminal: $0.terminal) },
            airline: history.airline.map { GateCount(gate: $0.gate, terminal: $0.terminal, flights: u32($0.flights)) },
            airlineCode: TravelFacts.airlineCode(ident: flight.ident))
        return p.map(GatePrediction.init)
    }

    /// `YYYY-MM-DD` of the flight's scheduled departure at its origin: the day `gate_history` counts back from.
    public static func departureDay(_ flight: Flight, originTimeZone: TimeZone?) -> String? {
        guard let out = flight.scheduledOut ?? flight.estimatedOut else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = originTimeZone ?? .gmt
        let c = cal.dateComponents([.year, .month, .day], from: out)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Signals

    /// The leg that brings the plane, when it ends where this flight starts: its arrival (the schedule
    /// plus its delay) and whether it has left its gate.
    static func inboundSignal(_ flight: Flight, _ leg: InboundLeg?) -> InboundSignal? {
        guard let leg, leg.status != .canceled, leg.status != .diverted else { return nil }
        if let origin = flight.originIata, leg.destinationIata != origin, leg.destinationIata != flight.originIcao {
            return nil
        }
        let arrival = leg.scheduledIn.addingTimeInterval(TimeInterval(max(0, leg.delayMinutes) * 60))
        let moving: Set<FlightStatus> = [.departed, .enRoute, .landed, .arrived]
        return InboundSignal(arrival: epoch(arrival), departed: moving.contains(leg.status))
    }

    /// The weather impact around `date`: the worst TAF period in force, else the current observation
    /// when `date` is within `metarHorizon` of now.
    static func weatherSignal(_ weather: Weather?, at date: Date?, now: Date) -> WeatherSignal? {
        guard let weather, let date else { return nil }
        let impact: WeatherImpact
        if let f = weather.forecastImpact(at: date) {
            impact = f.impact
        } else if abs(date.timeIntervalSince(now)) <= metarHorizon {
            impact = WeatherImpact.of(weather)
        } else {
            return nil
        }
        return WeatherSignal(level: impact.level.core, affects: impact.affects.map(\.core))
    }

    private static func epoch(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }
    private static func u32(_ v: Int) -> UInt32 { UInt32(clamping: max(0, v)) }
}

private extension WeatherImpact.Level {
    var core: ImpactLevel {
        switch self { case .none: .clear; case .minor: .minor; case .moderate: .moderate; case .severe: .severe }
    }
}

private extension WeatherImpact.Side {
    var core: Affects {
        switch self { case .arrivals: .arrivals; case .departures: .departures; case .both: .both }
    }
}

extension DelayPrediction {
    init(_ p: FlightCore.DelayPrediction) {
        let reason: Reason = switch p.reason {
        case .lateInbound: .lateInbound
        case .originWeather: .originWeather
        case .destinationWeather: .destinationWeather
        case .congestion: .congestion
        case .history: .history
        }
        let confidence: Confidence = switch p.confidence { case .low: .low; case .medium: .medium; case .high: .high }
        self.init(minutes: Int(p.minutes), reason: reason, confidence: confidence, reasonTitle: p.reasonTitle,
                  summary: p.summary)
    }
}

extension GatePrediction {
    init(_ p: FlightCore.GatePrediction) {
        let guess: Guess = switch p.guess { case .gate: .gate; case .concourse: .concourse; case .terminal: .terminal }
        self.init(guess: guess, gate: p.gate, concourse: p.concourse, terminal: p.terminal, used: Int(p.used),
                  of: Int(p.of), fromAirline: p.fromAirline, label: p.label, detail: p.detail)
    }
}
