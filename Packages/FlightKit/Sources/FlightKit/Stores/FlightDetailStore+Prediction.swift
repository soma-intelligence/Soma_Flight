import Foundation

// The flight sheet's predictions: the likely departure delay before the airline moves its estimate, and the
// likely gate before one is assigned. Both are read by the Rust core (`Predictions`) from what the sheet
// already loaded; only the gate history is a call of its own, and a free one.
extension FlightDetailStore {
    /// The likely departure delay at `now` (the inbound plane, both airports' weather, the origin's board
    /// and the flight number's record); nil when the signals are weak, the flight left or ended, or the
    /// airline's estimate already shows it. A Passport flight has none.
    public func delayPrediction(now: Date) -> DelayPrediction? {
        guard !isArchived, let f = flight else { return nil }
        return Predictions.delay(f, inbound: inbound, forecast: forecast, originStats: originStats,
                                 originWeather: originWeather, destinationWeather: destinationWeather, now: now)
    }

    /// The likely departure gate, concourse or terminal; nil as soon as the real gate is known.
    public var gatePrediction: GatePrediction? {
        guard !isArchived, let f = flight else { return nil }
        return Predictions.gate(f, history: gateHistory)
    }

    /// The gate history for a flight with no departure gate yet that has not left; nil otherwise or when
    /// the call fails (the prediction is a nicety: a failure hides it, never an error banner).
    nonisolated static func gateHistory(_ service: any GateHistoryService, flight f: Flight,
                                        originTimeZone: TimeZone?) async -> GateHistory? {
        guard f.gateOrigin == nil, f.status == .scheduled || f.status == .unknown,
              let day = Predictions.departureDay(f, originTimeZone: originTimeZone) else { return nil }
        return try? await service.gateHistory(ident: f.ident, origin: f.originIcao, operator: f.operator, day: day)
    }
}
