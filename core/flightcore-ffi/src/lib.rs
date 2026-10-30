//! UniFFI binding of `flightcore` for Swift (iOS and macOS apps).
//!
//! The core crate stays free of FFI dependencies: every exported type here is
//! a mirror of a core type with `From` conversions both ways where needed.
//! Built into `Packages/FlightCoreFFI/FlightCoreFFI.xcframework` by
//! `core/scripts/build-xcframework.sh`.

use flightcore::{aircraft, delay, geo, passport, passport_detail, weather};

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
    fn from(geo::Coord { lat, lon }: geo::Coord) -> Self {
        Self { lat, lon }
    }
}

/// Haversine distance in kilometres.
#[uniffi::export]
pub fn distance_km(a: Coord, b: Coord) -> f64 {
    geo::distance_km(a.into(), b.into())
}

/// `segments + 1` points along the great circle from `a` to `b`, longitudes
/// unwrapped so neighbours differ by under 180 degrees. `segments` is clamped
/// to `1..=geo::MAX_SEGMENTS` (100,000) to bound memory; the WASM binding
/// rejects values above the cap instead.
#[uniffi::export]
pub fn great_circle(a: Coord, b: Coord, segments: u32) -> Vec<Coord> {
    geo::great_circle(a.into(), b.into(), segments.min(geo::MAX_SEGMENTS))
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
        // Struct literal: a new core field fails to compile here.
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
    fn from(
        delay::HourBucket {
            hour,
            on_time,
            late15,
            late45,
            canceled,
            diverted,
        }: delay::HourBucket,
    ) -> Self {
        Self {
            hour,
            on_time,
            late15,
            late45,
            canceled,
            diverted,
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
    fn from(
        delay::RouteStat {
            icao,
            delayed,
            canceled,
        }: delay::RouteStat,
    ) -> Self {
        Self {
            icao,
            delayed,
            canceled,
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
    fn from(
        delay::AirlineStat {
            operator,
            delayed,
            canceled,
        }: delay::AirlineStat,
    ) -> Self {
        Self {
            operator,
            delayed,
            canceled,
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
    fn from(
        delay::DelayStats {
            total,
            on_time,
            delayed15,
            canceled,
            avg_delay_minutes,
            per_hour,
            worst_routes,
            worst_airlines,
            severity,
        }: delay::DelayStats,
    ) -> Self {
        Self {
            total,
            on_time,
            delayed15,
            canceled,
            avg_delay_minutes,
            per_hour: per_hour.into_iter().map(Into::into).collect(),
            worst_routes: worst_routes.into_iter().map(Into::into).collect(),
            worst_airlines: worst_airlines.into_iter().map(Into::into).collect(),
            severity: severity.into(),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SeatClass {
    Economy,
    PremiumEconomy,
    Business,
    First,
    Private,
}

impl From<SeatClass> for passport::SeatClass {
    fn from(s: SeatClass) -> Self {
        match s {
            SeatClass::Economy => Self::Economy,
            SeatClass::PremiumEconomy => Self::PremiumEconomy,
            SeatClass::Business => Self::Business,
            SeatClass::First => Self::First,
            SeatClass::Private => Self::Private,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TripReason {
    Personal,
    Business,
    Crew,
}

impl From<TripReason> for passport::TripReason {
    fn from(r: TripReason) -> Self {
        match r {
            TripReason::Personal => Self::Personal,
            TripReason::Business => Self::Business,
            TripReason::Crew => Self::Crew,
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
    #[uniffi(default)]
    pub origin_country: Option<String>,
    #[uniffi(default)]
    pub destination_country: Option<String>,
    #[uniffi(default)]
    pub air_minutes: Option<u32>,
    #[uniffi(default)]
    pub registration: Option<String>,
    #[uniffi(default)]
    pub seat_class: Option<SeatClass>,
    #[uniffi(default)]
    pub seat: Option<String>,
    #[uniffi(default)]
    pub reason: Option<TripReason>,
    #[uniffi(default)]
    pub seat_position: Option<SeatPosition>,
}

impl From<PastFlight> for passport::PastFlight {
    fn from(f: PastFlight) -> Self {
        // Struct literal: a new core field fails to compile here.
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
            origin_country: f.origin_country,
            destination_country: f.destination_country,
            air_minutes: f.air_minutes,
            registration: f.registration,
            seat_class: f.seat_class.map(Into::into),
            seat: f.seat,
            reason: f.reason.map(Into::into),
            seat_position: f.seat_position.map(Into::into),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AircraftCount {
    pub aircraft_type: String,
    pub count: u32,
}

impl From<passport::AircraftCount> for AircraftCount {
    fn from(
        passport::AircraftCount {
            aircraft_type,
            count,
        }: passport::AircraftCount,
    ) -> Self {
        Self {
            aircraft_type,
            count,
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
    pub delayed_flights: u32,
    pub avg_delayed_minutes: u32,
    pub most_flown_aircraft: Option<AircraftCount>,
    pub routes: Vec<RoutePair>,
}

impl From<passport::PassportStats> for PassportStats {
    fn from(
        passport::PassportStats {
            flights,
            long_haul,
            distance_km,
            flight_minutes,
            airports,
            airlines,
            delay_lost_minutes,
            avg_delay_minutes,
            delayed_flights,
            avg_delayed_minutes,
            most_flown_aircraft,
            routes,
        }: passport::PassportStats,
    ) -> Self {
        Self {
            flights,
            long_haul,
            distance_km,
            flight_minutes,
            airports,
            airlines,
            delay_lost_minutes,
            avg_delay_minutes,
            delayed_flights,
            avg_delayed_minutes,
            most_flown_aircraft: most_flown_aircraft.map(Into::into),
            routes: routes
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

// Passport detail

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
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

impl From<Region> for passport_detail::Region {
    fn from(r: Region) -> Self {
        match r {
            Region::Europe => Self::Europe,
            Region::NorthAmerica => Self::NorthAmerica,
            Region::CentralAmerica => Self::CentralAmerica,
            Region::Caribbean => Self::Caribbean,
            Region::SouthAmerica => Self::SouthAmerica,
            Region::Africa => Self::Africa,
            Region::MiddleEast => Self::MiddleEast,
            Region::Asia => Self::Asia,
            Region::Oceania => Self::Oceania,
        }
    }
}

impl From<passport_detail::Region> for Region {
    fn from(r: passport_detail::Region) -> Self {
        use passport_detail::Region as R;
        match r {
            R::Europe => Self::Europe,
            R::NorthAmerica => Self::NorthAmerica,
            R::CentralAmerica => Self::CentralAmerica,
            R::Caribbean => Self::Caribbean,
            R::SouthAmerica => Self::SouthAmerica,
            R::Africa => Self::Africa,
            R::MiddleEast => Self::MiddleEast,
            R::Asia => Self::Asia,
            R::Oceania => Self::Oceania,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CountryInfo {
    pub iso2: String,
    pub region: Region,
}

impl From<CountryInfo> for passport_detail::CountryInfo {
    fn from(c: CountryInfo) -> Self {
        Self {
            iso2: c.iso2,
            region: c.region.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct YearCount {
    pub year: i32,
    pub flights: u32,
}

impl From<passport_detail::YearCount> for YearCount {
    fn from(passport_detail::YearCount { year, flights }: passport_detail::YearCount) -> Self {
        Self { year, flights }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FlightRef {
    pub ident: String,
    pub origin_icao: String,
    pub destination_icao: String,
    pub departed_at: i64,
    pub distance_km: u32,
    pub block_minutes: Option<u32>,
    pub airline: Option<String>,
}

impl From<passport_detail::FlightRef> for FlightRef {
    fn from(
        passport_detail::FlightRef {
            ident,
            origin_icao,
            destination_icao,
            departed_at,
            distance_km,
            block_minutes,
            airline,
        }: passport_detail::FlightRef,
    ) -> Self {
        Self {
            ident,
            origin_icao,
            destination_icao,
            departed_at,
            distance_km,
            block_minutes,
            airline,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AirportVisits {
    pub icao: String,
    pub visits: u32,
}

impl From<passport_detail::AirportVisits> for AirportVisits {
    fn from(
        passport_detail::AirportVisits { icao, visits }: passport_detail::AirportVisits,
    ) -> Self {
        Self { icao, visits }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Tally {
    pub key: String,
    pub flights: u32,
    pub distance_km: u64,
}

impl From<passport_detail::Tally> for Tally {
    fn from(
        passport_detail::Tally {
            key,
            flights,
            distance_km,
        }: passport_detail::Tally,
    ) -> Self {
        Self {
            key,
            flights,
            distance_km,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CountryCount {
    pub iso2: String,
    pub flights: u32,
}

impl From<passport_detail::CountryCount> for CountryCount {
    fn from(
        passport_detail::CountryCount { iso2, flights }: passport_detail::CountryCount,
    ) -> Self {
        Self { iso2, flights }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RegionCount {
    pub region: Region,
    pub visited: u32,
    pub total: u32,
}

impl From<passport_detail::RegionCount> for RegionCount {
    fn from(
        passport_detail::RegionCount {
            region,
            visited,
            total,
        }: passport_detail::RegionCount,
    ) -> Self {
        Self {
            region: region.into(),
            visited,
            total,
        }
    }
}

/// `per_month` holds 12 counts (January first) and `per_weekday` 7 (Monday first).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PassportDetail {
    pub flights: u32,
    pub domestic: u32,
    pub international: u32,
    pub long_haul: u32,
    pub per_year: Vec<YearCount>,
    pub per_month: Vec<u32>,
    pub per_weekday: Vec<u32>,
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

fn mapped<A, B: From<A>>(v: Vec<A>) -> Vec<B> {
    v.into_iter().map(Into::into).collect()
}

impl From<passport_detail::PassportDetail> for PassportDetail {
    fn from(d: passport_detail::PassportDetail) -> Self {
        // Exhaustive destructuring: a new core field fails to compile here.
        let passport_detail::PassportDetail {
            flights,
            domestic,
            international,
            long_haul,
            per_year,
            per_month,
            per_weekday,
            distance_km,
            avg_distance_km,
            earth_ratio,
            moon_ratio,
            sun_ratio,
            shortest_by_distance,
            longest_by_distance,
            shortest_by_time,
            longest_by_time,
            flight_minutes,
            avg_flight_minutes,
            air_minutes,
            taxi_minutes,
            airports,
            airlines_by_flights,
            airlines_by_distance,
            routes_by_flights,
            routes_by_distance,
            countries,
            unknown_country_flights,
            regions,
        } = d;
        Self {
            flights,
            domestic,
            international,
            long_haul,
            per_year: mapped(per_year),
            per_month: per_month.to_vec(),
            per_weekday: per_weekday.to_vec(),
            distance_km,
            avg_distance_km,
            earth_ratio,
            moon_ratio,
            sun_ratio,
            shortest_by_distance: shortest_by_distance.map(Into::into),
            longest_by_distance: longest_by_distance.map(Into::into),
            shortest_by_time: shortest_by_time.map(Into::into),
            longest_by_time: longest_by_time.map(Into::into),
            flight_minutes,
            avg_flight_minutes,
            air_minutes,
            taxi_minutes,
            airports: mapped(airports),
            airlines_by_flights: mapped(airlines_by_flights),
            airlines_by_distance: mapped(airlines_by_distance),
            routes_by_flights: mapped(routes_by_flights),
            routes_by_distance: mapped(routes_by_distance),
            countries: mapped(countries),
            unknown_country_flights,
            regions: mapped(regions),
        }
    }
}

/// Full Passport statistics over completed and diverted flights, optionally
/// limited to one local departure year (`per_year` always covers all time).
/// `countries` is the reference list behind the region totals.
#[uniffi::export]
pub fn compute_passport_detail(
    flights: Vec<PastFlight>,
    year: Option<i32>,
    countries: Vec<CountryInfo>,
) -> PassportDetail {
    let flights: Vec<passport::PastFlight> = mapped(flights);
    let countries: Vec<passport_detail::CountryInfo> = mapped(countries);
    passport_detail::compute_passport_detail(&flights, year, &countries).into()
}

// Aircraft stats

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TypeInfo {
    pub icao_type: String,
    pub family: String,
    pub manufacturer: String,
}

impl From<TypeInfo> for aircraft::TypeInfo {
    fn from(t: TypeInfo) -> Self {
        Self {
            icao_type: t.icao_type,
            family: t.family,
            manufacturer: t.manufacturer,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AircraftFact {
    pub registration: String,
    /// Unix seconds.
    pub delivered_at: Option<i64>,
    pub name: Option<String>,
}

impl From<AircraftFact> for aircraft::AircraftFact {
    fn from(x: AircraftFact) -> Self {
        Self {
            registration: x.registration,
            delivered_at: x.delivered_at,
            name: x.name,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SeatPosition {
    Window,
    Middle,
    Aisle,
    Pilot,
    Captain,
    Jumpseat,
}

impl From<aircraft::SeatPosition> for SeatPosition {
    fn from(p: aircraft::SeatPosition) -> Self {
        match p {
            aircraft::SeatPosition::Window => Self::Window,
            aircraft::SeatPosition::Middle => Self::Middle,
            aircraft::SeatPosition::Aisle => Self::Aisle,
            aircraft::SeatPosition::Pilot => Self::Pilot,
            aircraft::SeatPosition::Captain => Self::Captain,
            aircraft::SeatPosition::Jumpseat => Self::Jumpseat,
        }
    }
}

impl From<SeatPosition> for aircraft::SeatPosition {
    fn from(p: SeatPosition) -> Self {
        match p {
            SeatPosition::Window => Self::Window,
            SeatPosition::Middle => Self::Middle,
            SeatPosition::Aisle => Self::Aisle,
            SeatPosition::Pilot => Self::Pilot,
            SeatPosition::Captain => Self::Captain,
            SeatPosition::Jumpseat => Self::Jumpseat,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Share {
    pub key: String,
    pub flights: u32,
    pub percent: u32,
}

impl From<aircraft::Share> for Share {
    fn from(
        aircraft::Share {
            key,
            flights,
            percent,
        }: aircraft::Share,
    ) -> Self {
        Self {
            key,
            flights,
            percent,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TypeTally {
    pub icao_type: String,
    pub flights: u32,
    pub minutes: u64,
    pub distance_km: u64,
}

impl From<aircraft::TypeTally> for TypeTally {
    fn from(
        aircraft::TypeTally {
            icao_type,
            flights,
            minutes,
            distance_km,
        }: aircraft::TypeTally,
    ) -> Self {
        Self {
            icao_type,
            flights,
            minutes,
            distance_km,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TailTally {
    pub registration: String,
    pub flights: u32,
    pub icao_type: Option<String>,
    pub airline: Option<String>,
    pub name: Option<String>,
}

impl From<aircraft::TailTally> for TailTally {
    fn from(
        aircraft::TailTally {
            registration,
            flights,
            icao_type,
            airline,
            name,
        }: aircraft::TailTally,
    ) -> Self {
        Self {
            registration,
            flights,
            icao_type,
            airline,
            name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeatClassCounts {
    pub economy: u32,
    pub premium_economy: u32,
    pub business: u32,
    pub first: u32,
    pub private: u32,
}

impl From<aircraft::SeatClassCounts> for SeatClassCounts {
    fn from(
        aircraft::SeatClassCounts {
            economy,
            premium_economy,
            business,
            first,
            private,
        }: aircraft::SeatClassCounts,
    ) -> Self {
        Self {
            economy,
            premium_economy,
            business,
            first,
            private,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PositionCounts {
    pub window: u32,
    pub middle: u32,
    pub aisle: u32,
    pub pilot: u32,
    pub captain: u32,
    pub jumpseat: u32,
}

impl From<aircraft::PositionCounts> for PositionCounts {
    fn from(
        aircraft::PositionCounts {
            window,
            middle,
            aisle,
            pilot,
            captain,
            jumpseat,
        }: aircraft::PositionCounts,
    ) -> Self {
        Self {
            window,
            middle,
            aisle,
            pilot,
            captain,
            jumpseat,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SeatTally {
    pub seat: String,
    pub flights: u32,
}

impl From<aircraft::SeatTally> for SeatTally {
    fn from(aircraft::SeatTally { seat, flights }: aircraft::SeatTally) -> Self {
        Self { seat, flights }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReasonCounts {
    pub personal: u32,
    pub business: u32,
    pub crew: u32,
}

impl From<aircraft::ReasonCounts> for ReasonCounts {
    fn from(
        aircraft::ReasonCounts {
            personal,
            business,
            crew,
        }: aircraft::ReasonCounts,
    ) -> Self {
        Self {
            personal,
            business,
            crew,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DecadeCount {
    pub decade: i32,
    pub aircraft: u32,
}

impl From<aircraft::DecadeCount> for DecadeCount {
    fn from(aircraft::DecadeCount { decade, aircraft }: aircraft::DecadeCount) -> Self {
        Self { decade, aircraft }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgedAircraft {
    pub registration: String,
    pub icao_type: Option<String>,
    /// Unix seconds.
    pub delivered_at: i64,
    pub age_months: u32,
}

impl From<aircraft::AgedAircraft> for AgedAircraft {
    fn from(
        aircraft::AgedAircraft {
            registration,
            icao_type,
            delivered_at,
            age_months,
        }: aircraft::AgedAircraft,
    ) -> Self {
        Self {
            registration,
            icao_type,
            delivered_at,
            age_months,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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

impl From<aircraft::AircraftStats> for AircraftStats {
    fn from(s: aircraft::AircraftStats) -> Self {
        // Exhaustive destructuring: a new core field fails to compile here.
        let aircraft::AircraftStats {
            total_types,
            manufacturers,
            types_by_flights,
            types_by_minutes,
            types_by_distance,
            most_flown,
            tails,
            seat_classes,
            seat_positions,
            favourite_seat,
            reasons,
            decades,
            median_age_months,
            newest,
            oldest,
        } = s;
        Self {
            total_types,
            manufacturers: mapped(manufacturers),
            types_by_flights: mapped(types_by_flights),
            types_by_minutes: mapped(types_by_minutes),
            types_by_distance: mapped(types_by_distance),
            most_flown: most_flown.map(Into::into),
            tails: mapped(tails),
            seat_classes: seat_classes.into(),
            seat_positions: seat_positions.into(),
            favourite_seat: favourite_seat.map(Into::into),
            reasons: reasons.into(),
            decades: mapped(decades),
            median_age_months,
            newest: newest.map(Into::into),
            oldest: oldest.map(Into::into),
        }
    }
}

/// Aircraft statistics over completed and diverted flights, optionally limited
/// to one local departure year. `types` is the reference behind manufacturers
/// and seat positions, `facts` the delivery dates and names behind ages, and
/// `as_of` (unix seconds) the instant ages are measured to.
#[uniffi::export]
pub fn compute_aircraft_stats(
    flights: Vec<PastFlight>,
    year: Option<i32>,
    types: Vec<TypeInfo>,
    facts: Vec<AircraftFact>,
    as_of: i64,
) -> AircraftStats {
    let flights: Vec<passport::PastFlight> = mapped(flights);
    let types: Vec<aircraft::TypeInfo> = mapped(types);
    let facts: Vec<aircraft::AircraftFact> = mapped(facts);
    aircraft::compute_aircraft_stats(&flights, year, &types, &facts, as_of).into()
}

/// Window, middle or aisle for a seat ("23A") in the economy layout of an
/// aircraft family ("a320", "b777", ...); nil for other families or letters.
#[uniffi::export]
pub fn seat_position(seat: String, family: String) -> Option<SeatPosition> {
    aircraft::seat_position(&seat, &family).map(Into::into)
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
            origin_country: None,
            destination_country: None,
            air_minutes: None,
            registration: None,
            seat_class: None,
            seat: None,
            reason: None,
            seat_position: None,
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
        let d = compute_passport_detail(vec![], None, vec![]);
        assert_eq!(
            (d.per_month.len(), d.per_weekday.len(), d.regions.len()),
            (12, 7, 9)
        );
        assert_eq!(d.regions[1].region, Region::NorthAmerica);
        let s = compute_aircraft_stats(vec![], None, vec![], vec![], 0);
        assert!(s.most_flown.is_none() && s.median_age_months.is_none());
        assert_eq!(
            seat_position("12A".into(), "a320".into()),
            Some(SeatPosition::Window)
        );
    }

    #[test]
    fn great_circle_segments_are_capped() {
        let a = Coord { lat: 0.0, lon: 0.0 };
        let b = Coord {
            lat: 10.0,
            lon: 10.0,
        };
        let cap = geo::MAX_SEGMENTS as usize;
        assert_eq!(great_circle(a, b, u32::MAX).len(), cap + 1);
        assert_eq!(great_circle(a, b, geo::MAX_SEGMENTS + 1).len(), cap + 1);
        assert_eq!(great_circle(a, b, geo::MAX_SEGMENTS).len(), cap + 1);
        assert_eq!(great_circle(a, b, 0).len(), 2);
    }
}
