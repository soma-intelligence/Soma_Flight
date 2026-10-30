//! Aircraft statistics over a member's past flights: types, manufacturers, tails, seats,
//! trip reasons and aircraft ages. Pure: no clock (`as_of` is passed in), no I/O.
//! Rules are pinned in core/fixtures/aircraft.json.

use crate::passport::{PastFlight, PastFlightStatus, SeatClass, TripReason, local_year};
use chrono::{DateTime, Datelike, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap};

/// One reference aircraft type: ICAO designator, family (`a320`, `b777`, ...) and manufacturer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeInfo {
    pub icao_type: String,
    pub family: String,
    pub manufacturer: String,
}

/// What is known about one airframe: its delivery date (unix seconds) and its name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AircraftFact {
    pub registration: String,
    pub delivered_at: Option<i64>,
    pub name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SeatPosition {
    Window,
    Middle,
    Aisle,
    /// Cockpit, right seat.
    Pilot,
    /// Cockpit, left seat.
    Captain,
    Jumpseat,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Share {
    pub key: String,
    pub flights: u32,
    pub percent: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TypeTally {
    pub icao_type: String,
    pub flights: u32,
    pub minutes: u64,
    pub distance_km: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TailTally {
    pub registration: String,
    pub flights: u32,
    pub icao_type: Option<String>,
    pub airline: Option<String>,
    pub name: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeatClassCounts {
    pub economy: u32,
    pub premium_economy: u32,
    pub business: u32,
    pub first: u32,
    pub private: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PositionCounts {
    pub window: u32,
    pub middle: u32,
    pub aisle: u32,
    pub pilot: u32,
    pub captain: u32,
    pub jumpseat: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeatTally {
    pub seat: String,
    pub flights: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReasonCounts {
    pub personal: u32,
    pub business: u32,
    pub crew: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DecadeCount {
    pub decade: i32,
    pub aircraft: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgedAircraft {
    pub registration: String,
    pub icao_type: Option<String>,
    pub delivered_at: i64,
    pub age_months: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AircraftStats {
    pub total_types: u32,
    pub manufacturers: Vec<Share>,
    pub types_by_flights: Vec<TypeTally>,
    pub types_by_minutes: Vec<TypeTally>,
    pub types_by_distance: Vec<TypeTally>,
    pub most_flown: Option<TypeTally>,
    pub tails: Vec<TailTally>,
    pub seat_classes: SeatClassCounts,
    pub seat_positions: PositionCounts,
    pub favourite_seat: Option<SeatTally>,
    pub reasons: ReasonCounts,
    pub decades: Vec<DecadeCount>,
    pub median_age_months: Option<u32>,
    pub newest: Option<AgedAircraft>,
    pub oldest: Option<AgedAircraft>,
}

/// Trimmed, upper case; `None` when empty.
fn code(s: Option<&str>) -> Option<String> {
    let t = s?.trim();
    (!t.is_empty()).then(|| t.to_uppercase())
}

/// Seat position from the economy layout of the family (`a320`, `b777`, ...). The seat is
/// trimmed and upper cased and must be 1 to 3 digits then a letter ("23A"). Other families,
/// letters or shapes give `None`.
pub fn seat_position(seat: &str, family: &str) -> Option<SeatPosition> {
    use SeatPosition::{Aisle, Middle, Window};
    let s = seat.trim().to_uppercase();
    let mut chars = s.chars();
    let letter = chars.next_back().filter(char::is_ascii_uppercase)?;
    let row = chars.as_str();
    if !(1..=3).contains(&row.len()) || !row.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let l = letter as u8;
    // (window, middle, aisle) letters per layout.
    let (window, middle, aisle): (&[u8], &[u8], &[u8]) = match family.trim().to_lowercase().as_str()
    {
        "a320" | "b737" | "b737max" | "b757" => (b"AF", b"BE", b"CD"),
        "a220" => (b"AF", b"E", b"CD"),
        "ejet" | "atr" => (b"AF", b"", b"CD"),
        "crj" => (b"AD", b"", b"BC"),
        "a350" | "b787" => (b"AK", b"BEJ", b"CDFH"),
        "b777" | "b747" | "a380" => (b"AK", b"BEFJ", b"CDGH"),
        "a330" => (b"AK", b"EF", b"CDGH"),
        "b767" => (b"AK", b"E", b"CDFH"),
        _ => return None,
    };
    if window.contains(&l) {
        Some(Window)
    } else if middle.contains(&l) {
        Some(Middle)
    } else if aisle.contains(&l) {
        Some(Aisle)
    } else {
        None
    }
}

/// Whole calendar months from `from` to `to` (UTC): a month counts once its day and time of day
/// are reached. 0 when `from` is after `to` or either instant is out of range.
pub fn age_months(from: i64, to: i64) -> u32 {
    let (Some(a), Some(b)) = (
        DateTime::<Utc>::from_timestamp(from, 0),
        DateTime::<Utc>::from_timestamp(to, 0),
    ) else {
        return 0;
    };
    let mut m = i64::from(b.year() - a.year()) * 12 + i64::from(b.month()) - i64::from(a.month());
    let day_time = |t: &DateTime<Utc>| (t.day(), t.num_seconds_from_midnight());
    if day_time(&b) < day_time(&a) {
        m -= 1;
    }
    u32::try_from(m.max(0)).unwrap_or(u32::MAX)
}

fn delivery_decade(t: i64) -> Option<i32> {
    DateTime::<Utc>::from_timestamp(t, 0).map(|d| d.year().div_euclid(10) * 10)
}

/// `100 * part / whole` rounded half up; 0 when `whole` is 0.
fn percent(part: u64, whole: u64) -> u32 {
    if whole == 0 {
        0
    } else {
        ((200 * part + whole) / (2 * whole)) as u32
    }
}

#[derive(Default)]
struct Tail {
    flights: u32,
    icao_type: Option<String>,
    airline: Option<String>,
}

pub fn compute_aircraft_stats(
    flights: &[PastFlight],
    year: Option<i32>,
    types: &[TypeInfo],
    facts: &[AircraftFact],
    as_of: i64,
) -> AircraftStats {
    let mut kept: Vec<&PastFlight> = flights
        .iter()
        .filter(|f| f.status != PastFlightStatus::Canceled)
        .filter(|f| year.is_none_or(|y| local_year(f) == Some(y)))
        .collect();
    kept.sort_by_key(|f| f.departed_at); // stable

    let mut reference: HashMap<String, &TypeInfo> = HashMap::new();
    for t in types {
        if let Some(k) = code(Some(&t.icao_type)) {
            reference.entry(k).or_insert(t);
        }
    }
    let mut fact_of: HashMap<String, &AircraftFact> = HashMap::new();
    for x in facts {
        if let Some(k) = code(Some(&x.registration)) {
            fact_of.entry(k).or_insert(x);
        }
    }

    let mut per_type: BTreeMap<String, TypeTally> = BTreeMap::new();
    let mut per_maker: BTreeMap<&str, u32> = BTreeMap::new();
    let mut tails: BTreeMap<String, Tail> = BTreeMap::new();
    let mut seats: BTreeMap<String, u32> = BTreeMap::new();
    let mut classes = SeatClassCounts::default();
    let mut positions = PositionCounts::default();
    let mut reasons = ReasonCounts::default();

    for f in &kept {
        let ty = code(f.aircraft_type.as_deref());
        let info = ty.as_ref().and_then(|t| reference.get(t)).copied();
        if let Some(t) = &ty {
            let e = per_type.entry(t.clone()).or_insert_with(|| TypeTally {
                icao_type: t.clone(),
                flights: 0,
                minutes: 0,
                distance_km: 0,
            });
            e.flights += 1;
            e.minutes += u64::from(f.block_minutes.unwrap_or(0));
            e.distance_km += u64::from(f.distance_km);
        }
        if let Some(info) = info {
            *per_maker.entry(info.manufacturer.as_str()).or_insert(0) += 1;
        }
        if let Some(r) = code(f.registration.as_deref()) {
            let tail = tails.entry(r).or_default();
            tail.flights += 1;
            // Flights are in departure order: the latest value wins.
            if ty.is_some() {
                tail.icao_type = ty.clone();
            }
            if let Some(a) = f.airline.as_deref().filter(|a| !a.is_empty()) {
                tail.airline = Some(a.to_string());
            }
        }
        match f.seat_class {
            Some(SeatClass::Economy) => classes.economy += 1,
            Some(SeatClass::PremiumEconomy) => classes.premium_economy += 1,
            Some(SeatClass::Business) => classes.business += 1,
            Some(SeatClass::First) => classes.first += 1,
            Some(SeatClass::Private) => classes.private += 1,
            None => {}
        }
        match f.reason {
            Some(TripReason::Personal) => reasons.personal += 1,
            Some(TripReason::Business) => reasons.business += 1,
            Some(TripReason::Crew) => reasons.crew += 1,
            None => {}
        }
        let seat = code(f.seat.as_deref());
        // The position the traveller picked wins; else it comes from the seat and the cabin layout.
        let position = f.seat_position.or_else(|| {
            let (seat, info) = (seat.as_ref()?, info?);
            seat_position(seat, &info.family)
        });
        match position {
            Some(SeatPosition::Window) => positions.window += 1,
            Some(SeatPosition::Middle) => positions.middle += 1,
            Some(SeatPosition::Aisle) => positions.aisle += 1,
            Some(SeatPosition::Pilot) => positions.pilot += 1,
            Some(SeatPosition::Captain) => positions.captain += 1,
            Some(SeatPosition::Jumpseat) => positions.jumpseat += 1,
            None => {}
        }
        if let Some(seat) = seat {
            *seats.entry(seat).or_insert(0) += 1;
        }
    }

    let on_reference: u64 = per_maker.values().map(|&n| u64::from(n)).sum();
    let mut manufacturers: Vec<Share> = per_maker
        .into_iter()
        .map(|(key, flights)| Share {
            key: key.to_string(),
            flights,
            percent: percent(u64::from(flights), on_reference),
        })
        .collect();
    // BTreeMap order is key ascending; a stable sort by count keeps it as the tie break.
    manufacturers.sort_by_key(|s| Reverse(s.flights));

    let rows: Vec<TypeTally> = per_type.into_values().collect();
    let mut types_by_flights = rows.clone();
    types_by_flights.sort_by_key(|t| Reverse(t.flights));
    let mut types_by_minutes = rows.clone();
    types_by_minutes.sort_by_key(|t| (Reverse(t.minutes), Reverse(t.flights)));
    let mut types_by_distance = rows;
    types_by_distance.sort_by_key(|t| (Reverse(t.distance_km), Reverse(t.flights)));

    let mut aged: Vec<AgedAircraft> = Vec::new();
    let mut tail_rows: Vec<TailTally> = Vec::with_capacity(tails.len());
    for (registration, t) in tails {
        let fact = fact_of.get(&registration);
        if let Some(delivered_at) = fact.and_then(|x| x.delivered_at) {
            aged.push(AgedAircraft {
                registration: registration.clone(),
                icao_type: t.icao_type.clone(),
                delivered_at,
                age_months: age_months(delivered_at, as_of),
            });
        }
        tail_rows.push(TailTally {
            registration,
            flights: t.flights,
            icao_type: t.icao_type,
            airline: t.airline,
            name: fact.and_then(|x| x.name.clone()),
        });
    }
    tail_rows.sort_by_key(|t| Reverse(t.flights));

    let mut per_decade: BTreeMap<i32, u32> = BTreeMap::new();
    for a in &aged {
        if let Some(d) = delivery_decade(a.delivered_at) {
            *per_decade.entry(d).or_insert(0) += 1;
        }
    }
    let decades = match (
        per_decade.keys().next().copied(),
        per_decade.keys().next_back().copied(),
    ) {
        (Some(first), Some(last)) => (first..=last)
            .step_by(10)
            .map(|decade| DecadeCount {
                decade,
                aircraft: per_decade.get(&decade).copied().unwrap_or(0),
            })
            .collect(),
        _ => Vec::new(),
    };

    let mut ages: Vec<u32> = aged.iter().map(|a| a.age_months).collect();
    ages.sort_unstable();
    let median_age_months = ages.get(ages.len().saturating_sub(1) / 2).copied();
    // `aged` is in registration order, so `min_by_key` keeps the first registration on ties.
    let newest = aged.iter().min_by_key(|a| Reverse(a.delivered_at)).cloned();
    let oldest = aged.iter().min_by_key(|a| a.delivered_at).cloned();

    let mut favourite: Option<(String, u32)> = None;
    for (seat, n) in seats {
        if favourite.as_ref().is_none_or(|(_, best)| n > *best) {
            favourite = Some((seat, n));
        }
    }

    AircraftStats {
        total_types: types_by_flights.len() as u32,
        manufacturers,
        most_flown: types_by_flights.first().cloned(),
        types_by_flights,
        types_by_minutes,
        types_by_distance,
        tails: tail_rows,
        seat_classes: classes,
        seat_positions: positions,
        favourite_seat: favourite.map(|(seat, flights)| SeatTally { seat, flights }),
        reasons,
        decades,
        median_age_months,
        newest,
        oldest,
    }
}
