//! Full Passport statistics over a member's past flights: splits, calendars,
//! distance and time records, airport visits, tallies, countries and regions.
//! Pure: no clock, no I/O. Rules are pinned in core/fixtures/passport_detail.json.

use crate::passport::{LONG_HAUL_KM, PastFlight, PastFlightStatus, local_departure, local_year};
use chrono::Datelike;
use serde::{Deserialize, Serialize};
use std::cmp::Reverse;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// Circumference of the Earth at the equator.
pub const EARTH_KM: u64 = 40_075;
/// Mean distance from the Earth to the Moon.
pub const MOON_KM: u64 = 384_400;
/// Circumference of the Sun.
pub const SUN_KM: u64 = 4_375_250;
/// A stop shorter than this (landing to next departure) is a connection, not a visit.
pub const CONNECTION_SECONDS: i64 = 28_800;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Region {
    Europe,
    NorthAmerica,
    CentralAmerica,
    Caribbean,
    SouthAmerica,
    Africa,
    MiddleEast,
    Asia,
    Oceania,
}

impl Region {
    /// Declaration order.
    pub const ALL: [Region; 9] = [
        Region::Europe,
        Region::NorthAmerica,
        Region::CentralAmerica,
        Region::Caribbean,
        Region::SouthAmerica,
        Region::Africa,
        Region::MiddleEast,
        Region::Asia,
        Region::Oceania,
    ];
}

/// One reference country: its ISO 3166-1 alpha-2 code and its region.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CountryInfo {
    pub iso2: String,
    pub region: Region,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct YearCount {
    pub year: i32,
    pub flights: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlightRef {
    pub ident: String,
    pub origin_icao: String,
    pub destination_icao: String,
    pub departed_at: i64,
    pub distance_km: u32,
    pub block_minutes: Option<u32>,
    pub airline: Option<String>,
}

impl From<&PastFlight> for FlightRef {
    fn from(f: &PastFlight) -> Self {
        Self {
            ident: f.ident.clone(),
            origin_icao: f.origin_icao.clone(),
            destination_icao: f.destination_icao.clone(),
            departed_at: f.departed_at,
            distance_km: f.distance_km,
            block_minutes: f.block_minutes,
            airline: f.airline.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AirportVisits {
    pub icao: String,
    pub visits: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tally {
    pub key: String,
    pub flights: u32,
    pub distance_km: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CountryCount {
    pub iso2: String,
    pub flights: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegionCount {
    pub region: Region,
    pub visited: u32,
    pub total: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PassportDetail {
    pub flights: u32,
    pub domestic: u32,
    pub international: u32,
    pub long_haul: u32,
    pub per_year: Vec<YearCount>,
    pub per_month: [u32; 12],
    pub per_weekday: [u32; 7],
    pub distance_km: u64,
    pub avg_distance_km: u32,
    pub earth_ratio: f64,
    pub moon_ratio: f64,
    pub sun_ratio: f64,
    pub shortest_by_distance: Option<FlightRef>,
    pub longest_by_distance: Option<FlightRef>,
    pub shortest_by_time: Option<FlightRef>,
    pub longest_by_time: Option<FlightRef>,
    pub flight_minutes: u64,
    pub avg_flight_minutes: u64,
    pub air_minutes: u64,
    pub taxi_minutes: u64,
    pub airports: Vec<AirportVisits>,
    pub airlines_by_flights: Vec<Tally>,
    pub airlines_by_distance: Vec<Tally>,
    pub routes_by_flights: Vec<Tally>,
    pub routes_by_distance: Vec<Tally>,
    pub countries: Vec<CountryCount>,
    pub unknown_country_flights: u32,
    pub regions: Vec<RegionCount>,
}

/// `total / n` rounded half up; 0 when `n` is 0.
fn avg(total: u64, n: u64) -> u64 {
    if n == 0 { 0 } else { (2 * total + n) / (2 * n) }
}

fn known(c: &Option<String>) -> Option<&str> {
    c.as_deref().filter(|c| !c.is_empty())
}

/// First flight (in departure order) whose key beats every earlier one, so ties keep the earliest.
fn first_best<'a, K: Ord>(
    flights: impl Iterator<Item = &'a PastFlight>,
    key: impl Fn(&PastFlight) -> K,
    better: std::cmp::Ordering,
) -> Option<FlightRef> {
    let mut best: Option<(&PastFlight, K)> = None;
    for f in flights {
        let k = key(f);
        if best.as_ref().is_none_or(|(_, bk)| k.cmp(bk) == better) {
            best = Some((f, k));
        }
    }
    best.map(|(f, _)| f.into())
}

/// Tallies by key, sorted by flights then by distance (each with the other measure and the key as tie breaks).
fn tallies<'a>(
    flights: &[&'a PastFlight],
    key: impl Fn(&'a PastFlight) -> Option<String>,
) -> (Vec<Tally>, Vec<Tally>) {
    let mut map: BTreeMap<String, (u32, u64)> = BTreeMap::new();
    for f in flights {
        if let Some(k) = key(f) {
            let e = map.entry(k).or_insert((0, 0));
            e.0 += 1;
            e.1 += u64::from(f.distance_km);
        }
    }
    let rows: Vec<Tally> = map
        .into_iter()
        .map(|(key, (flights, distance_km))| Tally {
            key,
            flights,
            distance_km,
        })
        .collect();
    let mut by_flights = rows.clone();
    by_flights.sort_by(|a, b| {
        (Reverse(a.flights), Reverse(a.distance_km), &a.key).cmp(&(
            Reverse(b.flights),
            Reverse(b.distance_km),
            &b.key,
        ))
    });
    let mut by_distance = rows;
    by_distance.sort_by(|a, b| {
        (Reverse(a.distance_km), Reverse(a.flights), &a.key).cmp(&(
            Reverse(b.distance_km),
            Reverse(b.flights),
            &b.key,
        ))
    });
    (by_flights, by_distance)
}

/// Airport visits over flights already sorted by departure: the destination always gets a visit,
/// the origin too unless the previous flight landed there under `CONNECTION_SECONDS` before.
/// A missing block time counts as 0 (the previous departure stands in for its landing).
pub fn airport_visits(sorted: &[&PastFlight]) -> Vec<AirportVisits> {
    let mut visits: HashMap<&str, u32> = HashMap::new();
    let mut prev: Option<&PastFlight> = None;
    for f in sorted {
        *visits.entry(&f.destination_icao).or_insert(0) += 1;
        let connection = prev.is_some_and(|p| {
            let landed = p.departed_at + 60 * i64::from(p.block_minutes.unwrap_or(0));
            p.destination_icao == f.origin_icao && f.departed_at - landed < CONNECTION_SECONDS
        });
        if !connection {
            *visits.entry(&f.origin_icao).or_insert(0) += 1;
        }
        prev = Some(f);
    }
    let mut out: Vec<AirportVisits> = visits
        .into_iter()
        .map(|(icao, visits)| AirportVisits {
            icao: icao.to_string(),
            visits,
        })
        .collect();
    out.sort_by(|a, b| b.visits.cmp(&a.visits).then_with(|| a.icao.cmp(&b.icao)));
    out
}

pub fn compute_passport_detail(
    flights: &[PastFlight],
    year: Option<i32>,
    countries: &[CountryInfo],
) -> PassportDetail {
    let mut counted: Vec<&PastFlight> = flights
        .iter()
        .filter(|f| f.status != PastFlightStatus::Canceled)
        .collect();
    counted.sort_by_key(|f| f.departed_at); // stable

    let mut years: BTreeMap<i32, u32> = BTreeMap::new();
    for f in &counted {
        if let Some(y) = local_year(f) {
            *years.entry(y).or_insert(0) += 1;
        }
    }

    let kept: Vec<&PastFlight> = counted
        .iter()
        .copied()
        .filter(|f| year.is_none_or(|y| local_year(f) == Some(y)))
        .collect();
    let n = kept.len() as u64;

    let (mut domestic, mut international, mut unknown) = (0u32, 0u32, 0u32);
    let mut per_country: BTreeMap<&str, u32> = BTreeMap::new();
    for f in &kept {
        let (o, d) = (known(&f.origin_country), known(&f.destination_country));
        match (o, d) {
            (Some(o), Some(d)) if o == d => domestic += 1,
            (Some(_), Some(_)) => international += 1,
            _ => unknown += 1,
        }
        let once: BTreeSet<&str> = o.into_iter().chain(d).collect();
        for c in once {
            *per_country.entry(c).or_insert(0) += 1;
        }
    }

    let mut per_month = [0u32; 12];
    let mut per_weekday = [0u32; 7];
    for f in &kept {
        if let Some(t) = local_departure(f) {
            per_month[t.month0() as usize] += 1;
            per_weekday[t.weekday().num_days_from_monday() as usize] += 1;
        }
    }

    let distance_km: u64 = kept.iter().map(|f| u64::from(f.distance_km)).sum();
    let timed = || kept.iter().copied().filter(|f| f.block_minutes.is_some());
    let flight_minutes: u64 = timed()
        .map(|f| u64::from(f.block_minutes.unwrap_or(0)))
        .sum();
    let ratio = |c: u64| distance_km as f64 / c as f64;

    let (airlines_by_flights, airlines_by_distance) = tallies(&kept, |f| {
        f.airline
            .as_deref()
            .filter(|a| !a.is_empty())
            .map(str::to_string)
    });
    let (routes_by_flights, routes_by_distance) = tallies(&kept, |f| {
        Some(format!("{}-{}", f.origin_icao, f.destination_icao))
    });

    let mut country_rows: Vec<CountryCount> = per_country
        .iter()
        .map(|(c, n)| CountryCount {
            iso2: c.to_string(),
            flights: *n,
        })
        .collect();
    // BTreeMap order is iso2 ascending; a stable sort by count keeps it as the tie break.
    country_rows.sort_by_key(|c| Reverse(c.flights));

    let region_of: HashMap<&str, Region> = countries
        .iter()
        .map(|c| (c.iso2.as_str(), c.region))
        .collect();
    let regions = Region::ALL
        .iter()
        .map(|&r| RegionCount {
            region: r,
            visited: per_country
                .keys()
                .filter(|c| region_of.get(*c) == Some(&r))
                .count() as u32,
            total: countries.iter().filter(|c| c.region == r).count() as u32,
        })
        .collect();

    PassportDetail {
        flights: n as u32,
        domestic,
        international,
        long_haul: kept
            .iter()
            .filter(|f| f.distance_km >= LONG_HAUL_KM)
            .count() as u32,
        per_year: years
            .into_iter()
            .map(|(year, flights)| YearCount { year, flights })
            .collect(),
        per_month,
        per_weekday,
        distance_km,
        avg_distance_km: avg(distance_km, n) as u32,
        earth_ratio: ratio(EARTH_KM),
        moon_ratio: ratio(MOON_KM),
        sun_ratio: ratio(SUN_KM),
        shortest_by_distance: first_best(
            kept.iter().copied(),
            |f| f.distance_km,
            std::cmp::Ordering::Less,
        ),
        longest_by_distance: first_best(
            kept.iter().copied(),
            |f| f.distance_km,
            std::cmp::Ordering::Greater,
        ),
        shortest_by_time: first_best(timed(), |f| f.block_minutes, std::cmp::Ordering::Less),
        longest_by_time: first_best(timed(), |f| f.block_minutes, std::cmp::Ordering::Greater),
        flight_minutes,
        avg_flight_minutes: avg(flight_minutes, timed().count() as u64),
        air_minutes: kept
            .iter()
            .map(|f| u64::from(f.air_minutes.unwrap_or(0)))
            .sum(),
        taxi_minutes: kept
            .iter()
            .filter_map(|f| Some(f.block_minutes?.saturating_sub(f.air_minutes?)))
            .map(u64::from)
            .sum(),
        airports: airport_visits(&kept),
        airlines_by_flights,
        airlines_by_distance,
        routes_by_flights,
        routes_by_distance,
        countries: country_rows,
        unknown_country_flights: unknown,
        regions,
    }
}
