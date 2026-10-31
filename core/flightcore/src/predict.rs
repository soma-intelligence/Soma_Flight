//! Predictions from data the app and the backend already hold: how late a followed flight is likely
//! to leave before the airline moves its estimate, and which gate it is likely to leave from before
//! one is assigned. No provider call stands behind either; the callers pass what they have cached.
//!
//! Delay. Four signals, each turned into minutes of likely departure delay:
//! - The inbound aircraft: its best known arrival at our origin plus a minimum turn for its size,
//!   against our scheduled departure. The strongest signal: a plane cannot leave before it is there.
//! - Weather impact (`impact.rs`) at the origin (departures slowed, or arrivals slowed so planes come
//!   in late) and at the destination (arrivals slowed: airlines hold departures for it).
//! - The origin's departures board right now (average delay and share 15 minutes late or more),
//!   only for a flight leaving within `BOARD_HORIZON_S`: a board says nothing about tomorrow.
//! - How the flight number arrived lately (`ArrivalForecast`): a prior that backs the others and, alone,
//!   gives at most a low confidence guess.
//!
//! The biggest one leads and names the reason; a quarter of the runner-up is added, since causes
//! overlap more than they stack. Confidence starts from the leader's own strength and rises one step
//! for each other signal that points the same way. Under `MIN_PREDICTION_MIN` there is no prediction,
//! and none once the airline's own estimate already says as much.
//!
//! Gate. The gates the flight number used on its recent days, then the concourse or terminal they
//! share, then where the airline usually leaves from at that airport.
//!
//! Pure: no clock (`now` is an argument), no I/O.

use crate::delay::FlightStatus;
use crate::impact::{Affects, ImpactLevel};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// MARK: Turn time

/// Rough cabin size from an ICAO type designator, for the turn a plane needs at the gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AircraftSize {
    /// Turboprops and regional jets (ATR, Dash 8, CRJ, E-Jets up to the E175).
    Regional,
    /// Single aisle jets (A320 family, 737, E190/E195 and the like).
    Narrow,
    /// Twin aisle jets (A330, A350, A380, 747, 767, 777, 787 and the like).
    Wide,
}

const WIDE: [&str; 13] = [
    "A30", "A31", "A33", "A34", "A35", "A38", "B74", "B76", "B77", "B78", "IL9", "MD1", "DC1",
];
const REGIONAL: [&str; 14] = [
    "AT4", "AT7", "DH8", "CRJ", "E13", "E14", "E17", "E45", "SF3", "B19", "J31", "J32", "D32",
    "E75",
];

/// The size of an ICAO type designator ("B77W", "A320", "E75L"); None when unknown or blank.
/// The A310 counts as wide; the A318 to A321 ("A318".."A321", "A20N", "A21N") are narrow.
pub fn aircraft_size(type_code: &str) -> Option<AircraftSize> {
    let t = type_code.trim().to_ascii_uppercase();
    if t.len() < 3 {
        return None;
    }
    // A318 to A321 share the "A31"/"A32" prefixes with the A310: name them first.
    if matches!(t.as_str(), "A318" | "A319" | "A320" | "A321") || t.starts_with("A2") {
        return Some(AircraftSize::Narrow);
    }
    let head = &t[..3];
    if WIDE.contains(&head) {
        Some(AircraftSize::Wide)
    } else if REGIONAL.contains(&head) {
        Some(AircraftSize::Regional)
    } else {
        Some(AircraftSize::Narrow)
    }
}

/// Shortest believable turn at the gate in minutes: 25 regional, 35 single aisle, 60 twin aisle,
/// 40 when the type is unknown.
pub fn min_turn_minutes(type_code: Option<&str>) -> i64 {
    match type_code.and_then(aircraft_size) {
        Some(AircraftSize::Regional) => 25,
        Some(AircraftSize::Narrow) => 35,
        Some(AircraftSize::Wide) => 60,
        None => 40,
    }
}

// MARK: Delay inputs

/// The plane that flies this flight, on its way in.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboundSignal {
    /// Best known gate arrival at this flight's origin (actual, else estimated), unix seconds.
    pub arrival: i64,
    /// The inbound leg has left its gate, so its arrival estimate is firm.
    pub departed: bool,
}

/// How the flight number arrived over its recent days (`ArrivalForecast`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistorySignal {
    /// Flights seen in the window.
    pub observed: u32,
    /// Share that arrived 15 minutes late or more, 0 to 100.
    pub late_percent: u32,
    /// Average delay of the late ones.
    pub average_late_minutes: u32,
}

/// The origin's departures right now (`DelayStats` of its departures board).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardSignal {
    pub total: u32,
    /// Flights 15 minutes late or more.
    pub delayed15: u32,
    /// Average delay over the board, on time flights included.
    pub avg_delay_minutes: f64,
}

/// Weather impact at one airport (`impact::weather_impact` of the conditions around the flight's time).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WeatherSignal {
    pub level: ImpactLevel,
    /// Side the hazards hit; None reads as no hazard.
    pub affects: Option<Affects>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DelayInput {
    pub status: FlightStatus,
    /// Scheduled gate departure, unix seconds.
    pub scheduled_out: i64,
    /// The airline's current estimate, unix seconds.
    pub estimated_out: Option<i64>,
    pub now: i64,
    /// ICAO type designator of the aircraft, for the turn time.
    #[serde(default)]
    pub aircraft_type: Option<String>,
    /// Codes the reason names ("SFO", "JFK"): IATA where known.
    pub origin_code: String,
    pub destination_code: String,
    #[serde(default)]
    pub inbound: Option<InboundSignal>,
    #[serde(default)]
    pub history: Option<HistorySignal>,
    #[serde(default)]
    pub board: Option<BoardSignal>,
    #[serde(default)]
    pub origin_weather: Option<WeatherSignal>,
    #[serde(default)]
    pub destination_weather: Option<WeatherSignal>,
}

// MARK: Delay outputs

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DelayReason {
    LateInbound,
    OriginWeather,
    DestinationWeather,
    Congestion,
    History,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Low,
    Medium,
    High,
}

impl Confidence {
    fn up(self) -> Confidence {
        match self {
            Confidence::Low => Confidence::Medium,
            _ => Confidence::High,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DelayPrediction {
    /// Likely departure delay, rounded to 5 minutes, at least `MIN_PREDICTION_MIN`.
    pub minutes: u32,
    pub reason: DelayReason,
    pub confidence: Confidence,
    /// Short title: "Late inbound aircraft", "Weather at SFO", "Airport congestion", "Often late".
    pub reason_title: String,
    /// One line: "Likely 25 min late: inbound aircraft running late".
    pub summary: String,
}

/// Below this the signals are too weak to say anything.
pub const MIN_PREDICTION_MIN: i64 = 15;
/// A departure delay the airline already publishes: the real number is on screen, no guess.
pub const PUBLISHED_DELAY_MIN: i64 = 15;
/// A board only speaks for flights leaving within three hours.
pub const BOARD_HORIZON_S: i64 = 3 * 3600;
/// An inbound late by less than this is noise in the estimates.
const INBOUND_MIN: i64 = 10;
/// A signal this big counts as agreeing with the leader.
const AGREE_MIN: i64 = 10;
/// Fewest flights a board or a history needs to count.
const BOARD_MIN_FLIGHTS: u32 = 10;
const HISTORY_MIN_FLIGHTS: u32 = 10;
/// Cap on any prediction: beyond that the airline will have said something.
const MAX_PREDICTION_MIN: i64 = 180;

struct Signal {
    reason: DelayReason,
    minutes: i64,
    confidence: Confidence,
}

fn inbound_signal(i: &DelayInput) -> Option<Signal> {
    let inbound = i.inbound.as_ref()?;
    let turn = min_turn_minutes(i.aircraft_type.as_deref());
    let ready = inbound.arrival + turn * 60;
    let late = (ready - i.scheduled_out).div_euclid(60);
    (late >= INBOUND_MIN).then_some(Signal {
        reason: DelayReason::LateInbound,
        minutes: late,
        confidence: if inbound.departed {
            Confidence::High
        } else {
            Confidence::Medium
        },
    })
}

fn weather_signal(w: Option<&WeatherSignal>, origin: bool) -> Option<Signal> {
    let w = w?;
    let affects = w.affects?;
    let departures = matches!(affects, Affects::Departures | Affects::Both);
    let arrivals = matches!(affects, Affects::Arrivals | Affects::Both);
    let severe = w.level == ImpactLevel::Severe;
    if w.level < ImpactLevel::Moderate {
        return None;
    }
    let minutes = match (origin, departures, arrivals) {
        // Departures slowed at the origin: ramp stops, de-icing, departure routes closed.
        (true, true, _) => {
            if severe {
                45
            } else {
                20
            }
        }
        // Arrivals slowed at the origin: the planes we leave on come in late.
        (true, false, true) => {
            if severe {
                20
            } else {
                10
            }
        }
        // Arrivals slowed at the destination: airlines hold departures for it.
        (false, _, true) => {
            if severe {
                40
            } else {
                15
            }
        }
        _ => return None,
    };
    Some(Signal {
        reason: if origin {
            DelayReason::OriginWeather
        } else {
            DelayReason::DestinationWeather
        },
        minutes,
        confidence: if severe {
            Confidence::Medium
        } else {
            Confidence::Low
        },
    })
}

fn board_signal(i: &DelayInput) -> Option<Signal> {
    let b = i.board.as_ref()?;
    if i.scheduled_out - i.now > BOARD_HORIZON_S || b.total < BOARD_MIN_FLIGHTS {
        return None;
    }
    if !b.avg_delay_minutes.is_finite() {
        return None;
    }
    let avg = b.avg_delay_minutes.round() as i64;
    let share = b.delayed15 * 100 / b.total;
    (avg >= MIN_PREDICTION_MIN && share >= 30).then_some(Signal {
        reason: DelayReason::Congestion,
        minutes: avg,
        confidence: if avg >= 45 && share >= 50 {
            Confidence::Medium
        } else {
            Confidence::Low
        },
    })
}

fn history_signal(h: Option<&HistorySignal>) -> Option<Signal> {
    let h = h?;
    if h.observed < HISTORY_MIN_FLIGHTS || h.late_percent < 50 || h.average_late_minutes < 15 {
        return None;
    }
    Some(Signal {
        reason: DelayReason::History,
        minutes: i64::from(h.average_late_minutes) * i64::from(h.late_percent.min(100)) / 100,
        confidence: Confidence::Low,
    })
}

/// Whether the history leans late at all, as support for another signal.
fn history_agrees(h: Option<&HistorySignal>) -> bool {
    h.is_some_and(|h| h.observed >= HISTORY_MIN_FLIGHTS && h.late_percent >= 40)
}

fn round5(m: i64) -> i64 {
    (m + 2).div_euclid(5) * 5
}

/// The reason's short title and the phrase the summary ends with.
fn reason_words(r: DelayReason, i: &DelayInput) -> (String, String) {
    match r {
        DelayReason::LateInbound => (
            "Late inbound aircraft".into(),
            "inbound aircraft running late".into(),
        ),
        DelayReason::OriginWeather => (
            format!("Weather at {}", i.origin_code),
            format!("weather at {}", i.origin_code),
        ),
        DelayReason::DestinationWeather => (
            format!("Weather at {}", i.destination_code),
            format!("weather at {}", i.destination_code),
        ),
        DelayReason::Congestion => (
            "Airport congestion".into(),
            format!("departures backed up at {}", i.origin_code),
        ),
        DelayReason::History => ("Often late".into(), "this flight often leaves late".into()),
    }
}

/// The likely departure delay of a flight that has not left yet, or None when the signals are weak,
/// the flight has left or ended, or the airline's estimate already shows the delay.
pub fn predict_delay(i: &DelayInput) -> Option<DelayPrediction> {
    if !matches!(i.status, FlightStatus::Scheduled | FlightStatus::Unknown) {
        return None;
    }
    let published = i
        .estimated_out
        .map(|e| (e - i.scheduled_out).div_euclid(60))
        .unwrap_or(0);
    if published >= PUBLISHED_DELAY_MIN {
        return None;
    }

    let mut signals: Vec<Signal> = [
        inbound_signal(i),
        weather_signal(i.origin_weather.as_ref(), true),
        weather_signal(i.destination_weather.as_ref(), false),
        board_signal(i),
        history_signal(i.history.as_ref()),
    ]
    .into_iter()
    .flatten()
    .collect();
    // Biggest first; on a tie the order above wins (inbound, weather, congestion, history).
    signals.sort_by_key(|s| std::cmp::Reverse(s.minutes));
    let lead = signals.first()?;
    let runner = signals.get(1).map_or(0, |s| s.minutes);
    let minutes = round5((lead.minutes + runner / 4).min(MAX_PREDICTION_MIN));
    if minutes < MIN_PREDICTION_MIN || minutes <= published + 5 {
        return None;
    }

    // A busy board in bad weather is the weather's doing: name the cause, not the symptom.
    let mut reason = lead.reason;
    if reason == DelayReason::Congestion
        && let Some(w) = signals
            .iter()
            .find(|s| s.reason == DelayReason::OriginWeather)
    {
        reason = w.reason;
    }

    let mut confidence = lead.confidence;
    let others = signals
        .iter()
        .skip(1)
        .filter(|s| s.minutes >= AGREE_MIN && s.reason != DelayReason::History)
        .count();
    for _ in 0..others {
        confidence = confidence.up();
    }
    if lead.reason != DelayReason::History && history_agrees(i.history.as_ref()) {
        confidence = confidence.up();
    }
    // The flight's record alone is a hunch, however late it ran.
    if lead.reason == DelayReason::History && others == 0 {
        confidence = Confidence::Low;
    }

    let (reason_title, phrase) = reason_words(reason, i);
    Some(DelayPrediction {
        minutes: minutes as u32,
        reason,
        confidence,
        reason_title,
        summary: format!("Likely {minutes} min late: {phrase}"),
    })
}

// MARK: Gate

/// The departure gate the flight number used on one day (the last one seen that day).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GateDay {
    /// Local day at the origin, "YYYY-MM-DD".
    pub day: String,
    pub gate: String,
    #[serde(default)]
    pub terminal: Option<String>,
}

/// How many of the airline's departures at the airport left from one gate, over recent days.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GateCount {
    pub gate: String,
    #[serde(default)]
    pub terminal: Option<String>,
    pub flights: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GateGuess {
    Gate,
    Concourse,
    Terminal,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatePrediction {
    pub guess: GateGuess,
    pub gate: Option<String>,
    pub concourse: Option<String>,
    pub terminal: Option<String>,
    /// Days (or, from the airline, flights) that agree, and how many were counted.
    pub used: u32,
    pub of: u32,
    /// True when the guess comes from the airline's other flights, not this flight number.
    pub from_airline: bool,
    /// What the badge shows: "B22", "Concourse B", "Terminal 2".
    pub label: String,
    /// Why: "Used 6 of the last 7 days", "Where AF usually departs".
    pub detail: String,
}

/// The concourse a gate sits in: its leading letters when digits follow ("B22" is "B", "D5A" is "D"),
/// None for a bare number or a name.
pub fn concourse_of(gate: &str) -> Option<String> {
    let g = gate.trim();
    let letters: String = g.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
    let rest = &g[letters.len()..];
    (!letters.is_empty() && letters.len() <= 2 && rest.starts_with(|c: char| c.is_ascii_digit()))
        .then(|| letters.to_ascii_uppercase())
}

/// Fewest agreeing days for a guess from the flight number's own record.
const GATE_MIN_DAYS: u32 = 3;
/// Fewest airline departures for a guess from the airline's habits.
const AIRLINE_MIN_FLIGHTS: u32 = 10;

/// The key with the most weight; ties go to the smallest key, so the answer is stable.
fn top<K: Ord + Clone>(counts: &BTreeMap<K, u32>) -> Option<(K, u32)> {
    counts
        .iter()
        .fold(None, |best: Option<(&K, u32)>, (k, n)| match best {
            Some((_, b)) if b >= *n => best,
            _ => Some((k, *n)),
        })
        .map(|(k, n)| (k.clone(), n))
}

/// The terminal most of `rows` name, where any does.
fn usual_terminal<'a>(rows: impl Iterator<Item = (&'a Option<String>, u32)>) -> Option<String> {
    let mut t: BTreeMap<String, u32> = BTreeMap::new();
    for (term, n) in rows {
        if let Some(term) = term.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            *t.entry(term.to_string()).or_default() += n;
        }
    }
    top(&t).map(|(k, _)| k)
}

fn days_detail(used: u32, of: u32) -> String {
    format!(
        "Used {used} of the last {of} {}",
        if of == 1 { "day" } else { "days" }
    )
}

/// The likely departure gate, or failing that the concourse or terminal, of a flight with no gate yet.
/// `days` are the flight number's recent days at this origin (one per day; a repeated day counts once,
/// the first row wins), `airline` the airline's departures there by gate, `airline_code` the code the
/// detail names ("AF"). Majorities only: a gate needs `GATE_MIN_DAYS` and more than half the days; the
/// airline's concourse needs 60 percent of at least `AIRLINE_MIN_FLIGHTS` flights, its terminal 70.
pub fn predict_gate(
    days: &[GateDay],
    airline: &[GateCount],
    airline_code: Option<&str>,
) -> Option<GatePrediction> {
    let mut seen = std::collections::BTreeSet::new();
    let days: Vec<&GateDay> = days
        .iter()
        .filter(|d| !d.gate.trim().is_empty() && seen.insert(d.day.clone()))
        .collect();
    let of = days.len() as u32;
    let majority = |n: u32| n >= GATE_MIN_DAYS && n * 2 > of;

    if of > 0 {
        let mut gates: BTreeMap<String, u32> = BTreeMap::new();
        let mut concourses: BTreeMap<String, u32> = BTreeMap::new();
        let mut terminals: BTreeMap<String, u32> = BTreeMap::new();
        for d in &days {
            *gates.entry(d.gate.trim().to_ascii_uppercase()).or_default() += 1;
            if let Some(c) = concourse_of(&d.gate) {
                *concourses.entry(c).or_default() += 1;
            }
            if let Some(t) = d
                .terminal
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                *terminals.entry(t.to_string()).or_default() += 1;
            }
        }
        if let Some((gate, used)) = top(&gates).filter(|(_, n)| majority(*n)) {
            let terminal = usual_terminal(
                days.iter()
                    .filter(|d| d.gate.trim().eq_ignore_ascii_case(&gate))
                    .map(|d| (&d.terminal, 1)),
            );
            return Some(GatePrediction {
                guess: GateGuess::Gate,
                concourse: concourse_of(&gate),
                label: gate.clone(),
                gate: Some(gate),
                terminal,
                used,
                of,
                from_airline: false,
                detail: days_detail(used, of),
            });
        }
        if let Some((concourse, used)) = top(&concourses).filter(|(_, n)| majority(*n)) {
            let terminal = usual_terminal(
                days.iter()
                    .filter(|d| concourse_of(&d.gate).as_deref() == Some(concourse.as_str()))
                    .map(|d| (&d.terminal, 1)),
            );
            return Some(GatePrediction {
                guess: GateGuess::Concourse,
                gate: None,
                label: format!("Concourse {concourse}"),
                concourse: Some(concourse),
                terminal,
                used,
                of,
                from_airline: false,
                detail: days_detail(used, of),
            });
        }
        if let Some((terminal, used)) = top(&terminals).filter(|(_, n)| majority(*n)) {
            return Some(GatePrediction {
                guess: GateGuess::Terminal,
                gate: None,
                concourse: None,
                label: format!("Terminal {terminal}"),
                terminal: Some(terminal),
                used,
                of,
                from_airline: false,
                detail: days_detail(used, of),
            });
        }
    }

    // The airline's habit at this airport.
    let total: u32 = airline.iter().map(|g| g.flights).sum();
    if total < AIRLINE_MIN_FLIGHTS {
        return None;
    }
    let detail = match airline_code.map(str::trim).filter(|s| !s.is_empty()) {
        Some(code) => format!("Where {code} usually departs"),
        None => "Where this airline usually departs".to_string(),
    };
    let mut concourses: BTreeMap<String, u32> = BTreeMap::new();
    let mut terminals: BTreeMap<String, u32> = BTreeMap::new();
    for g in airline {
        if let Some(c) = concourse_of(&g.gate) {
            *concourses.entry(c).or_default() += g.flights;
        }
        if let Some(t) = g
            .terminal
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            *terminals.entry(t.to_string()).or_default() += g.flights;
        }
    }
    if let Some((concourse, used)) = top(&concourses).filter(|(_, n)| n * 10 >= total * 6) {
        let terminal = usual_terminal(
            airline
                .iter()
                .filter(|g| concourse_of(&g.gate).as_deref() == Some(concourse.as_str()))
                .map(|g| (&g.terminal, g.flights)),
        );
        return Some(GatePrediction {
            guess: GateGuess::Concourse,
            gate: None,
            label: format!("Concourse {concourse}"),
            concourse: Some(concourse),
            terminal,
            used,
            of: total,
            from_airline: true,
            detail,
        });
    }
    if let Some((terminal, used)) = top(&terminals).filter(|(_, n)| n * 10 >= total * 7) {
        return Some(GatePrediction {
            guess: GateGuess::Terminal,
            gate: None,
            concourse: None,
            label: format!("Terminal {terminal}"),
            terminal: Some(terminal),
            used,
            of: total,
            from_airline: true,
            detail,
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_800_000_000; // scheduled departure
    const MIN: i64 = 60;

    fn base() -> DelayInput {
        DelayInput {
            status: FlightStatus::Scheduled,
            scheduled_out: T0,
            estimated_out: Some(T0),
            now: T0 - 2 * 3600,
            aircraft_type: Some("A320".into()),
            origin_code: "SFO".into(),
            destination_code: "JFK".into(),
            inbound: None,
            history: None,
            board: None,
            origin_weather: None,
            destination_weather: None,
        }
    }

    fn weather(level: ImpactLevel, affects: Affects) -> Option<WeatherSignal> {
        Some(WeatherSignal {
            level,
            affects: Some(affects),
        })
    }

    // Turn time

    #[test]
    fn sizes_and_turns() {
        assert_eq!(aircraft_size("B77W"), Some(AircraftSize::Wide));
        assert_eq!(aircraft_size("a359"), Some(AircraftSize::Wide));
        assert_eq!(aircraft_size("A310"), Some(AircraftSize::Wide));
        assert_eq!(aircraft_size("A321"), Some(AircraftSize::Narrow));
        assert_eq!(aircraft_size("A20N"), Some(AircraftSize::Narrow));
        assert_eq!(aircraft_size("B738"), Some(AircraftSize::Narrow));
        assert_eq!(aircraft_size("E75L"), Some(AircraftSize::Regional));
        assert_eq!(aircraft_size("CRJ9"), Some(AircraftSize::Regional));
        assert_eq!(aircraft_size("E190"), Some(AircraftSize::Narrow));
        assert_eq!(aircraft_size(" "), None);
        assert_eq!(min_turn_minutes(Some("B789")), 60);
        assert_eq!(min_turn_minutes(Some("DH8D")), 25);
        assert_eq!(min_turn_minutes(Some("B738")), 35);
        assert_eq!(min_turn_minutes(None), 40);
    }

    // One test per reason

    #[test]
    fn late_inbound_airborne_is_high() {
        // Lands 10 minutes before departure; a 35 minute turn makes it 25 late.
        let mut i = base();
        i.inbound = Some(InboundSignal {
            arrival: T0 - 10 * MIN,
            departed: true,
        });
        let p = predict_delay(&i).unwrap();
        assert_eq!(p.minutes, 25);
        assert_eq!(p.reason, DelayReason::LateInbound);
        assert_eq!(p.confidence, Confidence::High);
        assert_eq!(p.reason_title, "Late inbound aircraft");
        assert_eq!(
            p.summary,
            "Likely 25 min late: inbound aircraft running late"
        );
    }

    #[test]
    fn late_inbound_on_the_ground_is_medium() {
        let mut i = base();
        i.inbound = Some(InboundSignal {
            arrival: T0 - 10 * MIN,
            departed: false,
        });
        assert_eq!(predict_delay(&i).unwrap().confidence, Confidence::Medium);
    }

    #[test]
    fn wide_body_needs_a_longer_turn() {
        // The same arrival is 50 late for a 777 (60 minute turn).
        let mut i = base();
        i.aircraft_type = Some("B77W".into());
        i.inbound = Some(InboundSignal {
            arrival: T0 - 10 * MIN,
            departed: true,
        });
        assert_eq!(predict_delay(&i).unwrap().minutes, 50);
    }

    #[test]
    fn origin_weather_names_the_airport() {
        let mut i = base();
        i.origin_weather = weather(ImpactLevel::Severe, Affects::Both);
        let p = predict_delay(&i).unwrap();
        assert_eq!(p.reason, DelayReason::OriginWeather);
        assert_eq!(p.minutes, 45);
        assert_eq!(p.confidence, Confidence::Medium);
        assert_eq!(p.reason_title, "Weather at SFO");
        assert_eq!(p.summary, "Likely 45 min late: weather at SFO");
    }

    #[test]
    fn destination_weather_holds_departures() {
        let mut i = base();
        i.destination_weather = weather(ImpactLevel::Moderate, Affects::Arrivals);
        let p = predict_delay(&i).unwrap();
        assert_eq!(p.reason, DelayReason::DestinationWeather);
        assert_eq!(p.minutes, 15);
        assert_eq!(p.confidence, Confidence::Low);
        assert_eq!(p.reason_title, "Weather at JFK");
    }

    #[test]
    fn congestion_from_the_board() {
        let mut i = base();
        i.board = Some(BoardSignal {
            total: 40,
            delayed15: 24,
            avg_delay_minutes: 48.0,
        });
        let p = predict_delay(&i).unwrap();
        assert_eq!(p.reason, DelayReason::Congestion);
        assert_eq!(p.minutes, 50);
        assert_eq!(p.confidence, Confidence::Medium);
        assert_eq!(p.reason_title, "Airport congestion");
        assert_eq!(p.summary, "Likely 50 min late: departures backed up at SFO");
    }

    #[test]
    fn congestion_in_bad_weather_is_the_weather() {
        let mut i = base();
        i.board = Some(BoardSignal {
            total: 40,
            delayed15: 24,
            avg_delay_minutes: 48.0,
        });
        i.origin_weather = weather(ImpactLevel::Moderate, Affects::Departures);
        let p = predict_delay(&i).unwrap();
        assert_eq!(p.reason, DelayReason::OriginWeather);
        // 48 leads, a quarter of 20 is added: 53, rounded to 55.
        assert_eq!(p.minutes, 55);
        // Medium from the board, one agreeing signal.
        assert_eq!(p.confidence, Confidence::High);
    }

    #[test]
    fn history_alone_is_a_low_hunch() {
        let mut i = base();
        i.history = Some(HistorySignal {
            observed: 30,
            late_percent: 70,
            average_late_minutes: 40,
        });
        let p = predict_delay(&i).unwrap();
        assert_eq!(p.reason, DelayReason::History);
        assert_eq!(p.minutes, 30);
        assert_eq!(p.confidence, Confidence::Low);
        assert_eq!(p.reason_title, "Often late");
    }

    #[test]
    fn history_backs_another_signal() {
        let mut i = base();
        i.destination_weather = weather(ImpactLevel::Moderate, Affects::Arrivals);
        i.history = Some(HistorySignal {
            observed: 20,
            late_percent: 45,
            average_late_minutes: 20,
        });
        assert_eq!(predict_delay(&i).unwrap().confidence, Confidence::Medium);
    }

    // No prediction

    #[test]
    fn nothing_without_signals() {
        assert_eq!(predict_delay(&base()), None);
    }

    #[test]
    fn nothing_when_signals_are_weak() {
        let mut i = base();
        // Inbound 5 minutes late after the turn, minor weather, a calm board, a short history.
        i.inbound = Some(InboundSignal {
            arrival: T0 - 30 * MIN,
            departed: true,
        });
        i.origin_weather = weather(ImpactLevel::Minor, Affects::Both);
        i.board = Some(BoardSignal {
            total: 40,
            delayed15: 4,
            avg_delay_minutes: 6.0,
        });
        i.history = Some(HistorySignal {
            observed: 4,
            late_percent: 100,
            average_late_minutes: 60,
        });
        assert_eq!(predict_delay(&i), None);
    }

    #[test]
    fn nothing_once_the_airline_publishes_the_delay() {
        let mut i = base();
        i.inbound = Some(InboundSignal {
            arrival: T0 - 10 * MIN,
            departed: true,
        });
        i.estimated_out = Some(T0 + 20 * MIN);
        assert_eq!(predict_delay(&i), None);
        // A 10 minute estimate already covers a 15 minute guess.
        i.inbound = Some(InboundSignal {
            arrival: T0 - 20 * MIN,
            departed: true,
        });
        i.estimated_out = Some(T0 + 10 * MIN);
        assert_eq!(predict_delay(&i), None);
    }

    #[test]
    fn nothing_once_the_flight_left_or_ended() {
        for status in [
            FlightStatus::Departed,
            FlightStatus::EnRoute,
            FlightStatus::Canceled,
            FlightStatus::Diverted,
        ] {
            let mut i = base();
            i.status = status;
            i.inbound = Some(InboundSignal {
                arrival: T0,
                departed: true,
            });
            assert_eq!(predict_delay(&i), None, "{status:?}");
        }
    }

    #[test]
    fn a_board_says_nothing_about_tomorrow() {
        let mut i = base();
        i.now = T0 - 20 * 3600;
        i.board = Some(BoardSignal {
            total: 40,
            delayed15: 24,
            avg_delay_minutes: 48.0,
        });
        assert_eq!(predict_delay(&i), None);
        // Nor does a thin one.
        i.now = T0 - 3600;
        i.board = Some(BoardSignal {
            total: 5,
            delayed15: 5,
            avg_delay_minutes: 60.0,
        });
        assert_eq!(predict_delay(&i), None);
    }

    #[test]
    fn inputs_read_from_camel_case_json() {
        let i: DelayInput = serde_json::from_str(
            r#"{"status":"scheduled","scheduledOut":1800000000,"estimatedOut":null,"now":1799990000,
                "originCode":"SFO","destinationCode":"CDG",
                "inbound":{"arrival":1799999400,"departed":true},
                "originWeather":{"level":"moderate","affects":"departures"}}"#,
        )
        .unwrap();
        let p = predict_delay(&i).unwrap();
        // 40 minute turn for an unknown type: ready 30 late; weather 20 adds 5.
        assert_eq!(p.minutes, 35);
        let json = serde_json::to_value(&p).unwrap();
        assert_eq!(json["reason"], "lateInbound");
        assert_eq!(json["confidence"], "high");
        assert_eq!(json["reasonTitle"], "Late inbound aircraft");
    }

    // Gate

    fn day(d: &str, gate: &str, terminal: Option<&str>) -> GateDay {
        GateDay {
            day: d.into(),
            gate: gate.into(),
            terminal: terminal.map(Into::into),
        }
    }

    #[test]
    fn concourses() {
        assert_eq!(concourse_of("B22").as_deref(), Some("B"));
        assert_eq!(concourse_of("d5a").as_deref(), Some("D"));
        assert_eq!(concourse_of("22"), None);
        assert_eq!(concourse_of("Gate"), None);
        assert_eq!(concourse_of("ABC1"), None);
    }

    #[test]
    fn gate_used_most_days() {
        let mut days: Vec<GateDay> = (1..=6)
            .map(|n| day(&format!("2026-10-2{n}"), "B22", Some("2")))
            .collect();
        days.push(day("2026-10-27", "B24", Some("2")));
        let p = predict_gate(&days, &[], Some("AF")).unwrap();
        assert_eq!(p.guess, GateGuess::Gate);
        assert_eq!(p.label, "B22");
        assert_eq!(p.concourse.as_deref(), Some("B"));
        assert_eq!(p.terminal.as_deref(), Some("2"));
        assert_eq!((p.used, p.of), (6, 7));
        assert_eq!(p.detail, "Used 6 of the last 7 days");
        assert!(!p.from_airline);
    }

    #[test]
    fn a_repeated_day_counts_once() {
        let days = vec![
            day("2026-10-21", "B22", None),
            day("2026-10-21", "B22", None),
            day("2026-10-22", "B22", None),
            day("2026-10-23", "C3", None),
        ];
        // Two of three days: not enough days for a gate.
        let p = predict_gate(&days, &[], None);
        assert!(p.is_none());
    }

    #[test]
    fn concourse_when_gates_move_inside_it() {
        let days = vec![
            day("2026-10-21", "B22", Some("2")),
            day("2026-10-22", "B24", Some("2")),
            day("2026-10-23", "B26", Some("2")),
            day("2026-10-24", "C3", Some("2")),
        ];
        let p = predict_gate(&days, &[], None).unwrap();
        assert_eq!(p.guess, GateGuess::Concourse);
        assert_eq!(p.label, "Concourse B");
        assert_eq!(p.terminal.as_deref(), Some("2"));
        assert_eq!(p.detail, "Used 3 of the last 4 days");
    }

    #[test]
    fn terminal_when_only_the_terminal_holds() {
        let days = vec![
            day("2026-10-21", "12", Some("1")),
            day("2026-10-22", "14", Some("1")),
            day("2026-10-23", "40", Some("1")),
        ];
        let p = predict_gate(&days, &[], None).unwrap();
        assert_eq!(p.guess, GateGuess::Terminal);
        assert_eq!(p.label, "Terminal 1");
    }

    #[test]
    fn airline_habit_when_the_flight_has_no_record() {
        let airline = vec![
            GateCount {
                gate: "A10".into(),
                terminal: Some("International".into()),
                flights: 14,
            },
            GateCount {
                gate: "A12".into(),
                terminal: Some("International".into()),
                flights: 6,
            },
            GateCount {
                gate: "G91".into(),
                terminal: Some("International".into()),
                flights: 4,
            },
        ];
        let p = predict_gate(&[], &airline, Some("AF")).unwrap();
        assert_eq!(p.guess, GateGuess::Concourse);
        assert_eq!(p.label, "Concourse A");
        assert_eq!(p.terminal.as_deref(), Some("International"));
        assert_eq!((p.used, p.of), (20, 24));
        assert!(p.from_airline);
        assert_eq!(p.detail, "Where AF usually departs");
    }

    #[test]
    fn airline_terminal_when_concourses_split() {
        let airline = vec![
            GateCount {
                gate: "A10".into(),
                terminal: Some("2".into()),
                flights: 5,
            },
            GateCount {
                gate: "B4".into(),
                terminal: Some("2".into()),
                flights: 5,
            },
            GateCount {
                gate: "C1".into(),
                terminal: Some("2".into()),
                flights: 5,
            },
        ];
        let p = predict_gate(&[], &airline, None).unwrap();
        assert_eq!(p.guess, GateGuess::Terminal);
        assert_eq!(p.label, "Terminal 2");
        assert_eq!(p.detail, "Where this airline usually departs");
    }

    #[test]
    fn no_gate_guess_without_a_majority() {
        let days = vec![
            day("2026-10-21", "B22", None),
            day("2026-10-22", "C4", None),
            day("2026-10-23", "D6", None),
        ];
        let thin = vec![GateCount {
            gate: "A1".into(),
            terminal: None,
            flights: 4,
        }];
        assert_eq!(predict_gate(&days, &thin, None), None);
        assert_eq!(predict_gate(&[], &[], None), None);
    }
}
