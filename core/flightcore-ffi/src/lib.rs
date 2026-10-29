//! UniFFI binding of `flightcore` for Swift (iOS and macOS apps).
//!
//! The core crate stays free of FFI dependencies: every exported type here is
//! a mirror of a core type with `From` conversions both ways where needed.
//! Built into `Packages/FlightCoreFFI/FlightCoreFFI.xcframework` by
//! `core/scripts/build-xcframework.sh`.

use flightcore::{delay, geo, passport, weather};

uniffi::setup_scaffolding!();

// Geo

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Coord {
    pub lat: f64,
    pub lon: f64,
}

impl From<Coord> for geo::Coord {
    fn from(c: Coord) -> Self {
        Self {
            lat: c.lat,
            lon: c.lon,
        }
    }
}

impl From<geo::Coord> for Coord {
    fn from(c: geo::Coord) -> Self {
        Self {
            lat: c.lat,
            lon: c.lon,
        }
    }
}

/// Haversine distance in kilometres.
#[uniffi::export]
pub fn distance_km(a: Coord, b: Coord) -> f64 {
    geo::distance_km(a.into(), b.into())
}

/// `segments + 1` points along the great circle from `a` to `b` (0 clamps to
/// 1), longitudes unwrapped so neighbours differ by under 180 degrees.
#[uniffi::export]
pub fn great_circle(a: Coord, b: Coord, segments: u32) -> Vec<Coord> {
    geo::great_circle(a.into(), b.into(), segments)
        .into_iter()
        .map(Coord::from)
        .collect()
}

// Delay stats

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FlightStatus {
    Scheduled,
    Departed,
    EnRoute,
    Landed,
    Arrived,
    Canceled,
    Diverted,
    Unknown,
}

impl From<FlightStatus> for delay::FlightStatus {
    fn from(s: FlightStatus) -> Self {
        match s {
            FlightStatus::Scheduled => Self::Scheduled,
            FlightStatus::Departed => Self::Departed,
            FlightStatus::EnRoute => Self::EnRoute,
            FlightStatus::Landed => Self::Landed,
            FlightStatus::Arrived => Self::Arrived,
            FlightStatus::Canceled => Self::Canceled,
            FlightStatus::Diverted => Self::Diverted,
            FlightStatus::Unknown => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BoardFlight {
    pub ident: String,
    pub operator: Option<String>,
    pub other_icao: String,
    pub status: FlightStatus,
    pub scheduled: Option<i64>,
    pub estimated: Option<i64>,
    pub actual: Option<i64>,
}

impl From<BoardFlight> for delay::BoardFlight {
    fn from(r: BoardFlight) -> Self {
        Self {
            ident: r.ident,
            operator: r.operator,
            other_icao: r.other_icao,
            status: r.status.into(),
            scheduled: r.scheduled,
            estimated: r.estimated,
            actual: r.actual,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HourBucket {
    pub hour: i64,
    pub on_time: u32,
    pub late15: u32,
    pub late45: u32,
    pub canceled: u32,
    pub diverted: u32,
}

impl From<delay::HourBucket> for HourBucket {
    fn from(b: delay::HourBucket) -> Self {
        Self {
            hour: b.hour,
            on_time: b.on_time,
            late15: b.late15,
            late45: b.late45,
            canceled: b.canceled,
            diverted: b.diverted,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RouteStat {
    pub icao: String,
    pub delayed: u32,
    pub canceled: u32,
}

impl From<delay::RouteStat> for RouteStat {
    fn from(r: delay::RouteStat) -> Self {
        Self {
            icao: r.icao,
            delayed: r.delayed,
            canceled: r.canceled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AirlineStat {
    pub operator: String,
    pub delayed: u32,
    pub canceled: u32,
}

impl From<delay::AirlineStat> for AirlineStat {
    fn from(a: delay::AirlineStat) -> Self {
        Self {
            operator: a.operator,
            delayed: a.delayed,
            canceled: a.canceled,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Severity {
    Normal,
    Moderate,
    Major,
}

impl From<delay::Severity> for Severity {
    fn from(s: delay::Severity) -> Self {
        match s {
            delay::Severity::Normal => Self::Normal,
            delay::Severity::Moderate => Self::Moderate,
            delay::Severity::Major => Self::Major,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DelayStats {
    pub total: u32,
    pub on_time: u32,
    pub delayed15: u32,
    pub canceled: u32,
    pub avg_delay_minutes: f64,
    pub per_hour: Vec<HourBucket>,
    pub worst_routes: Vec<RouteStat>,
    pub worst_airlines: Vec<AirlineStat>,
    pub severity: Severity,
}

impl From<delay::DelayStats> for DelayStats {
    fn from(s: delay::DelayStats) -> Self {
        Self {
            total: s.total,
            on_time: s.on_time,
            delayed15: s.delayed15,
            canceled: s.canceled,
            avg_delay_minutes: s.avg_delay_minutes,
            per_hour: s.per_hour.into_iter().map(Into::into).collect(),
            worst_routes: s.worst_routes.into_iter().map(Into::into).collect(),
            worst_airlines: s.worst_airlines.into_iter().map(Into::into).collect(),
            severity: s.severity.into(),
        }
    }
}

/// Departure or arrival board statistics.
#[uniffi::export]
pub fn compute_stats(rows: Vec<BoardFlight>) -> DelayStats {
    let rows: Vec<delay::BoardFlight> = rows.into_iter().map(Into::into).collect();
    delay::compute_stats(&rows).into()
}

// Weather

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FlightCategory {
    Vfr,
    Mvfr,
    Ifr,
    Lifr,
}

impl From<weather::FlightCategory> for FlightCategory {
    fn from(c: weather::FlightCategory) -> Self {
        match c {
            weather::FlightCategory::Vfr => Self::Vfr,
            weather::FlightCategory::Mvfr => Self::Mvfr,
            weather::FlightCategory::Ifr => Self::Ifr,
            weather::FlightCategory::Lifr => Self::Lifr,
        }
    }
}

/// FAA flight category; a missing ceiling is unlimited, and a negative or
/// non-finite visibility is LIFR.
#[uniffi::export]
pub fn flight_category(ceiling_ft: Option<i32>, visibility_sm: f64) -> FlightCategory {
    weather::flight_category(ceiling_ft, visibility_sm).into()
}

// Passport

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PastFlightStatus {
    Completed,
    Canceled,
    Diverted,
}

impl From<PastFlightStatus> for passport::PastFlightStatus {
    fn from(s: PastFlightStatus) -> Self {
        match s {
            PastFlightStatus::Completed => Self::Completed,
            PastFlightStatus::Canceled => Self::Canceled,
            PastFlightStatus::Diverted => Self::Diverted,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PastFlight {
    pub departed_at: i64,
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

impl From<PastFlight> for passport::PastFlight {
    fn from(f: PastFlight) -> Self {
        Self {
            departed_at: f.departed_at,
            tz: f.tz,
            ident: f.ident,
            origin_icao: f.origin_icao,
            destination_icao: f.destination_icao,
            airline: f.airline,
            aircraft_type: f.aircraft_type,
            distance_km: f.distance_km,
            block_minutes: f.block_minutes,
            delay_minutes: f.delay_minutes,
            status: f.status.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AircraftCount {
    pub aircraft_type: String,
    pub count: u32,
}

impl From<passport::AircraftCount> for AircraftCount {
    fn from(a: passport::AircraftCount) -> Self {
        Self {
            aircraft_type: a.aircraft_type,
            count: a.count,
        }
    }
}

/// One directed route, `(origin, destination)` in the core crate.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RoutePair {
    pub origin: String,
    pub destination: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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
    pub routes: Vec<RoutePair>,
}

impl From<passport::PassportStats> for PassportStats {
    fn from(p: passport::PassportStats) -> Self {
        Self {
            flights: p.flights,
            long_haul: p.long_haul,
            distance_km: p.distance_km,
            flight_minutes: p.flight_minutes,
            airports: p.airports,
            airlines: p.airlines,
            delay_lost_minutes: p.delay_lost_minutes,
            avg_delay_minutes: p.avg_delay_minutes,
            most_flown_aircraft: p.most_flown_aircraft.map(Into::into),
            routes: p
                .routes
                .into_iter()
                .map(|(origin, destination)| RoutePair {
                    origin,
                    destination,
                })
                .collect(),
        }
    }
}

/// Passport totals over completed and diverted flights, optionally limited to
/// one local departure year.
#[uniffi::export]
pub fn compute_passport(flights: Vec<PastFlight>, year: Option<i32>) -> PassportStats {
    let flights: Vec<passport::PastFlight> = flights.into_iter().map(Into::into).collect();
    passport::compute_passport(&flights, year).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_become_pairs() {
        let f = |o: &str, d: &str| PastFlight {
            departed_at: 1_700_000_000,
            tz: "UTC".into(),
            ident: "X1".into(),
            origin_icao: o.into(),
            destination_icao: d.into(),
            airline: None,
            aircraft_type: None,
            distance_km: 500,
            block_minutes: None,
            delay_minutes: 0,
            status: PastFlightStatus::Completed,
        };
        let p = compute_passport(vec![f("KSFO", "KLAX"), f("KLAX", "KSFO")], None);
        assert_eq!(
            p.routes,
            vec![
                RoutePair {
                    origin: "KSFO".into(),
                    destination: "KLAX".into()
                },
                RoutePair {
                    origin: "KLAX".into(),
                    destination: "KSFO".into()
                },
            ]
        );
    }

    #[test]
    fn mirrors_match_core() {
        let a = Coord { lat: 0.0, lon: 0.0 };
        let b = Coord {
            lat: 0.0,
            lon: 90.0,
        };
        assert_eq!(distance_km(a, b), geo::distance_km(a.into(), b.into()));
        assert_eq!(great_circle(a, b, 0).len(), 2);
        assert_eq!(flight_category(None, f64::NAN), FlightCategory::Lifr);
        assert_eq!(compute_stats(vec![]).severity, Severity::Normal);
    }
}
