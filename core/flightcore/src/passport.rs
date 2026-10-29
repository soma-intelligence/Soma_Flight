//! Passport statistics over a member's past flights. Pure: no clock, no I/O.

use chrono::{DateTime, Datelike, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};

/// Flights of at least this distance are long haul.
const LONG_HAUL_KM: u32 = 4000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PastFlightStatus {
    Completed,
    Canceled,
    Diverted,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PastFlight {
    /// Departure instant, unix seconds.
    pub departed_at: i64,
    /// IANA zone of the departure airport; unknown values fall back to UTC.
    pub tz: String,
    pub ident: String,
    pub origin_icao: String,
    pub destination_icao: String,
    pub airline: Option<String>,
    pub aircraft_type: Option<String>,
    pub distance_km: u32,
    pub block_minutes: Option<u32>,
    pub delay_minutes: u32,
    pub status: PastFlightStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AircraftCount {
    pub aircraft_type: String,
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PassportStats {
    pub flights: u32,
    pub long_haul: u32,
    pub distance_km: u64,
    pub flight_minutes: u64,
    pub airports: u32,
    pub airlines: u32,
    pub delay_lost_minutes: u64,
    pub avg_delay_minutes: u32,
    pub most_flown_aircraft: Option<AircraftCount>,
    pub routes: Vec<(String, String)>,
}

/// Local calendar year of the departure, in the flight's own zone (UTC when unknown).
fn local_year(f: &PastFlight) -> Option<i32> {
    let utc = DateTime::<Utc>::from_timestamp(f.departed_at, 0)?;
    Some(match f.tz.parse::<Tz>() {
        Ok(tz) => utc.with_timezone(&tz).year(),
        Err(_) => utc.year(),
    })
}

pub fn compute_passport(flights: &[PastFlight], year: Option<i32>) -> PassportStats {
    let mut kept: Vec<&PastFlight> = flights
        .iter()
        .filter(|f| f.status != PastFlightStatus::Canceled)
        .filter(|f| year.is_none_or(|y| local_year(f) == Some(y)))
        .collect();
    kept.sort_by_key(|f| f.departed_at); // stable

    let n = kept.len() as u64;
    let delay: u64 = kept.iter().map(|f| u64::from(f.delay_minutes)).sum();
    let mut airports: HashSet<&str> = HashSet::new();
    let mut airlines: BTreeSet<&str> = BTreeSet::new();
    let mut types: BTreeMap<&str, u32> = BTreeMap::new();
    let mut seen: HashSet<(&str, &str)> = HashSet::new();
    let mut routes = Vec::new();
    for f in &kept {
        airports.insert(&f.origin_icao);
        airports.insert(&f.destination_icao);
        if let Some(a) = f.airline.as_deref().filter(|a| !a.is_empty()) {
            airlines.insert(a);
        }
        if let Some(t) = f.aircraft_type.as_deref() {
            *types.entry(t).or_insert(0) += 1;
        }
        if seen.insert((&f.origin_icao, &f.destination_icao)) {
            routes.push((f.origin_icao.clone(), f.destination_icao.clone()));
        }
    }
    // BTreeMap iterates alphabetically; strict `>` keeps the first (alphabetical) on ties.
    let mut best: Option<(&str, u32)> = None;
    for (t, c) in &types {
        if best.is_none_or(|(_, bc)| *c > bc) {
            best = Some((t, *c));
        }
    }

    PassportStats {
        flights: kept.len() as u32,
        long_haul: kept
            .iter()
            .filter(|f| f.distance_km >= LONG_HAUL_KM)
            .count() as u32,
        distance_km: kept.iter().map(|f| u64::from(f.distance_km)).sum(),
        flight_minutes: kept
            .iter()
            .map(|f| u64::from(f.block_minutes.unwrap_or(0)))
            .sum(),
        airports: airports.len() as u32,
        airlines: airlines.len() as u32,
        delay_lost_minutes: delay,
        avg_delay_minutes: if n == 0 {
            0
        } else {
            ((2 * delay + n) / (2 * n)) as u32
        },
        most_flown_aircraft: best.map(|(t, c)| AircraftCount {
            aircraft_type: t.to_string(),
            count: c,
        }),
        routes,
    }
}
