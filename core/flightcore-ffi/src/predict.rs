//! Predictions (`flightcore::predict`): the likely departure delay before the airline moves its
//! estimate, and the likely departure gate before one is assigned. Mirrors of the core types, as in
//! the rest of this crate.

use crate::{Affects, FlightStatus, ImpactLevel};
use flightcore::{impact, predict};

impl From<ImpactLevel> for impact::ImpactLevel {
    fn from(l: ImpactLevel) -> Self {
        match l {
            ImpactLevel::Clear => Self::None,
            ImpactLevel::Minor => Self::Minor,
            ImpactLevel::Moderate => Self::Moderate,
            ImpactLevel::Severe => Self::Severe,
        }
    }
}

impl From<Affects> for impact::Affects {
    fn from(a: Affects) -> Self {
        match a {
            Affects::Arrivals => Self::Arrivals,
            Affects::Departures => Self::Departures,
            Affects::Both => Self::Both,
        }
    }
}

/// The plane on its way in; see `flightcore::predict::InboundSignal`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct InboundSignal {
    /// Best known gate arrival at this flight's origin, unix seconds.
    pub arrival: i64,
    /// The inbound leg has left its gate.
    pub departed: bool,
}

/// How the flight number arrived lately; see `flightcore::predict::HistorySignal`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistorySignal {
    pub observed: u32,
    pub late_percent: u32,
    pub average_late_minutes: u32,
}

/// The origin's departures right now; see `flightcore::predict::BoardSignal`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BoardSignal {
    pub total: u32,
    pub delayed15: u32,
    pub avg_delay_minutes: f64,
}

/// Weather impact at one airport around the flight's time.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WeatherSignal {
    pub level: ImpactLevel,
    pub affects: Option<Affects>,
}

/// Everything the delay prediction reads; see `flightcore::predict::DelayInput`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DelayInput {
    pub status: FlightStatus,
    pub scheduled_out: i64,
    pub estimated_out: Option<i64>,
    pub now: i64,
    pub aircraft_type: Option<String>,
    pub origin_code: String,
    pub destination_code: String,
    pub inbound: Option<InboundSignal>,
    pub history: Option<HistorySignal>,
    pub board: Option<BoardSignal>,
    pub origin_weather: Option<WeatherSignal>,
    pub destination_weather: Option<WeatherSignal>,
}

impl From<WeatherSignal> for predict::WeatherSignal {
    fn from(w: WeatherSignal) -> Self {
        Self {
            level: w.level.into(),
            affects: w.affects.map(impact::Affects::from),
        }
    }
}

impl From<DelayInput> for predict::DelayInput {
    fn from(i: DelayInput) -> Self {
        // Struct literals: a new core field fails to compile here.
        Self {
            status: i.status.into(),
            scheduled_out: i.scheduled_out,
            estimated_out: i.estimated_out,
            now: i.now,
            aircraft_type: i.aircraft_type,
            origin_code: i.origin_code,
            destination_code: i.destination_code,
            inbound: i.inbound.map(|s| predict::InboundSignal {
                arrival: s.arrival,
                departed: s.departed,
            }),
            history: i.history.map(|h| predict::HistorySignal {
                observed: h.observed,
                late_percent: h.late_percent,
                average_late_minutes: h.average_late_minutes,
            }),
            board: i.board.map(|b| predict::BoardSignal {
                total: b.total,
                delayed15: b.delayed15,
                avg_delay_minutes: b.avg_delay_minutes,
            }),
            origin_weather: i.origin_weather.map(Into::into),
            destination_weather: i.destination_weather.map(Into::into),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DelayReason {
    LateInbound,
    OriginWeather,
    DestinationWeather,
    Congestion,
    History,
}

impl From<predict::DelayReason> for DelayReason {
    fn from(r: predict::DelayReason) -> Self {
        match r {
            predict::DelayReason::LateInbound => Self::LateInbound,
            predict::DelayReason::OriginWeather => Self::OriginWeather,
            predict::DelayReason::DestinationWeather => Self::DestinationWeather,
            predict::DelayReason::Congestion => Self::Congestion,
            predict::DelayReason::History => Self::History,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, uniffi::Enum)]
pub enum PredictionConfidence {
    Low,
    Medium,
    High,
}

impl From<predict::Confidence> for PredictionConfidence {
    fn from(c: predict::Confidence) -> Self {
        match c {
            predict::Confidence::Low => Self::Low,
            predict::Confidence::Medium => Self::Medium,
            predict::Confidence::High => Self::High,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DelayPrediction {
    pub minutes: u32,
    pub reason: DelayReason,
    pub confidence: PredictionConfidence,
    pub reason_title: String,
    pub summary: String,
}

impl From<predict::DelayPrediction> for DelayPrediction {
    fn from(
        predict::DelayPrediction {
            minutes,
            reason,
            confidence,
            reason_title,
            summary,
        }: predict::DelayPrediction,
    ) -> Self {
        Self {
            minutes,
            reason: reason.into(),
            confidence: confidence.into(),
            reason_title,
            summary,
        }
    }
}

/// The likely departure delay before the airline moves its estimate; nil when the signals are weak,
/// the flight left or ended, or the estimate already shows the delay.
#[uniffi::export]
pub fn predict_delay(input: DelayInput) -> Option<DelayPrediction> {
    predict::predict_delay(&input.into()).map(DelayPrediction::from)
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GateDay {
    /// Local day at the origin, "YYYY-MM-DD".
    pub day: String,
    pub gate: String,
    pub terminal: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GateCount {
    pub gate: String,
    pub terminal: Option<String>,
    pub flights: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GateGuess {
    Gate,
    Concourse,
    Terminal,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct GatePrediction {
    pub guess: GateGuess,
    pub gate: Option<String>,
    pub concourse: Option<String>,
    pub terminal: Option<String>,
    pub used: u32,
    pub of: u32,
    pub from_airline: bool,
    pub label: String,
    pub detail: String,
}

impl From<predict::GatePrediction> for GatePrediction {
    fn from(
        predict::GatePrediction {
            guess,
            gate,
            concourse,
            terminal,
            used,
            of,
            from_airline,
            label,
            detail,
        }: predict::GatePrediction,
    ) -> Self {
        Self {
            guess: match guess {
                predict::GateGuess::Gate => GateGuess::Gate,
                predict::GateGuess::Concourse => GateGuess::Concourse,
                predict::GateGuess::Terminal => GateGuess::Terminal,
            },
            gate,
            concourse,
            terminal,
            used,
            of,
            from_airline,
            label,
            detail,
        }
    }
}

/// The likely departure gate (or concourse, or terminal) from the flight number's recent days and the
/// airline's usual gates at the airport; nil without a clear majority.
#[uniffi::export]
pub fn predict_gate(
    days: Vec<GateDay>,
    airline: Vec<GateCount>,
    airline_code: Option<String>,
) -> Option<GatePrediction> {
    let days: Vec<predict::GateDay> = days
        .into_iter()
        .map(|d| predict::GateDay {
            day: d.day,
            gate: d.gate,
            terminal: d.terminal,
        })
        .collect();
    let airline: Vec<predict::GateCount> = airline
        .into_iter()
        .map(|g| predict::GateCount {
            gate: g.gate,
            terminal: g.terminal,
            flights: g.flights,
        })
        .collect();
    predict::predict_gate(&days, &airline, airline_code.as_deref()).map(GatePrediction::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mirrors_match_core() {
        assert_eq!(predict_gate(vec![], vec![], None), None);
        let p = predict_delay(DelayInput {
            status: FlightStatus::Scheduled,
            scheduled_out: 3600,
            estimated_out: None,
            now: 0,
            aircraft_type: Some("A320".into()),
            origin_code: "SFO".into(),
            destination_code: "CDG".into(),
            inbound: Some(InboundSignal {
                arrival: 3000,
                departed: true,
            }),
            history: None,
            board: None,
            origin_weather: Some(WeatherSignal {
                level: ImpactLevel::Clear,
                affects: None,
            }),
            destination_weather: None,
        })
        .unwrap();
        // Lands 10 minutes before departure, a 35 minute turn: 25 late.
        assert_eq!(p.minutes, 25);
        assert_eq!(p.reason, DelayReason::LateInbound);
        assert_eq!(p.confidence, PredictionConfidence::High);
    }
}
