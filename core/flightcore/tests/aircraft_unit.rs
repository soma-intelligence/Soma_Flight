use flightcore::aircraft::{
    AircraftFact, SeatPosition, TypeInfo, age_months, compute_aircraft_stats, seat_position,
};
use flightcore::passport::{PastFlight, PastFlightStatus};

const T0: i64 = 1_750_000_000;

fn f(departed_at: i64, ty: Option<&str>, reg: Option<&str>) -> PastFlight {
    PastFlight {
        departed_at,
        tz: "UTC".into(),
        ident: "XX1".into(),
        origin_icao: "AAAA".into(),
        destination_icao: "BBBB".into(),
        airline: Some("AAL".into()),
        aircraft_type: ty.map(Into::into),
        distance_km: 500,
        block_minutes: Some(60),
        delay_minutes: 0,
        status: PastFlightStatus::Completed,
        origin_country: None,
        destination_country: None,
        air_minutes: None,
        registration: reg.map(Into::into),
        seat_class: None,
        seat: None,
        reason: None,
        seat_position: None,
    }
}

fn ty(icao: &str, family: &str, maker: &str) -> TypeInfo {
    TypeInfo {
        icao_type: icao.into(),
        family: family.into(),
        manufacturer: maker.into(),
    }
}

fn fact(reg: &str, delivered_at: Option<i64>) -> AircraftFact {
    AircraftFact {
        registration: reg.into(),
        delivered_at,
        name: None,
    }
}

/// 2026-10-29 12:00 UTC.
const AS_OF: i64 = 1_793_275_200;

#[test]
fn seat_layouts_from_the_brief() {
    use SeatPosition::{Aisle, Middle, Window};
    let p = |s, fam| seat_position(s, fam);
    assert_eq!(p("12A", "a320"), Some(Window));
    assert_eq!(p("12B", "b737max"), Some(Middle));
    assert_eq!(p("12D", "b757"), Some(Aisle));
    assert_eq!(p("12B", "a220"), None);
    assert_eq!(p("12E", "a220"), Some(Middle));
    assert_eq!(p("12C", "ejet"), Some(Aisle));
    assert_eq!(p("12B", "atr"), None);
    assert_eq!(p("12D", "crj"), Some(Window));
    assert_eq!(p("12B", "crj"), Some(Aisle));
    assert_eq!(p("3A", "bizjet"), Some(Window));
    assert_eq!(p("3C", "bizjet"), Some(Window));
    assert_eq!(p("40J", "b787"), Some(Middle));
    assert_eq!(p("40H", "a350"), Some(Aisle));
    assert_eq!(p("40F", "b777"), Some(Middle));
    assert_eq!(p("40G", "a380"), Some(Aisle));
    assert_eq!(p("40K", "b747"), Some(Window));
    assert_eq!(p("40E", "a330"), Some(Middle));
    assert_eq!(p("40D", "a330"), Some(Aisle));
    assert_eq!(p("40E", "b767"), Some(Middle));
    assert_eq!(p("40F", "b767"), Some(Aisle));
    assert_eq!(p("40I", "b777"), None);
}

#[test]
fn seat_shapes_and_families() {
    assert_eq!(seat_position(" 7a ", " A320 "), Some(SeatPosition::Window));
    for bad in [
        "", "A", "7", "1234A", "12AB", "12 A", "-1A", "7\u{e9}", "\u{663}A",
    ] {
        assert_eq!(seat_position(bad, "a320"), None, "{bad:?}");
    }
    assert_eq!(seat_position("12A", "other"), None);
    assert_eq!(seat_position("12A", ""), None);
}

#[test]
fn whole_months_wait_for_day_and_time() {
    // 2021-10-29 12:00 UTC is exactly 60 months before AS_OF, one second later is 59.
    let d = 1_635_508_800;
    assert_eq!(age_months(d, AS_OF), 60);
    assert_eq!(age_months(d + 1, AS_OF), 59);
    assert_eq!(age_months(AS_OF + 1, AS_OF), 0);
    assert_eq!(age_months(i64::MAX, AS_OF), 0);
}

#[test]
fn empty_and_sparse_have_no_division_by_zero() {
    let s = compute_aircraft_stats(&[], None, &[], &[], AS_OF);
    assert_eq!(s.total_types, 0);
    assert!(s.manufacturers.is_empty() && s.most_flown.is_none());
    assert!(s.decades.is_empty() && s.median_age_months.is_none());
    assert!(s.newest.is_none() && s.oldest.is_none() && s.favourite_seat.is_none());

    // Only unknown types: they count as types, the manufacturer list stays empty.
    let s = compute_aircraft_stats(
        &[f(T0, Some("ZZZZ"), None), f(T0 + 60, None, None)],
        None,
        &[],
        &[],
        AS_OF,
    );
    assert_eq!(s.total_types, 1);
    assert!(s.manufacturers.is_empty());
    assert!(s.tails.is_empty());
}

#[test]
fn median_of_one_aircraft_is_its_age() {
    let s = compute_aircraft_stats(
        &[f(T0, Some("A320"), Some("F-GKXA"))],
        None,
        &[ty("A320", "a320", "Airbus")],
        &[fact("F-GKXA", Some(1_635_508_800))],
        AS_OF,
    );
    assert_eq!(s.median_age_months, Some(60));
    assert_eq!(s.newest, s.oldest);
    assert_eq!(s.newest.unwrap().age_months, 60);
}

#[test]
fn median_of_even_count_is_lower_middle() {
    let flights: Vec<PastFlight> = ["A", "B", "C", "D"]
        .iter()
        .enumerate()
        .map(|(i, r)| f(T0 + i as i64, Some("A320"), Some(r)))
        .collect();
    // Ages 13, 25, 37 and 49 months: the lower middle is 25.
    let year = 365 * 86_400 + 6 * 3600;
    let facts: Vec<AircraftFact> = ["A", "B", "C", "D"]
        .iter()
        .enumerate()
        .map(|(i, r)| fact(r, Some(AS_OF - (i as i64 + 1) * year - 40 * 86_400)))
        .collect();
    let s = compute_aircraft_stats(&flights, None, &[], &facts, AS_OF);
    assert_eq!(s.median_age_months, Some(25));
}

#[test]
fn canceled_flights_count_nowhere() {
    let mut c = f(T0, Some("A320"), Some("F-GKXA"));
    c.status = PastFlightStatus::Canceled;
    let s = compute_aircraft_stats(&[c], None, &[ty("A320", "a320", "Airbus")], &[], AS_OF);
    assert_eq!(s.total_types, 0);
    assert!(s.tails.is_empty() && s.manufacturers.is_empty());
}

#[test]
fn reference_and_codes_compare_case_insensitively() {
    let s = compute_aircraft_stats(
        &[
            f(T0, Some("a320 "), Some("f-gkxa")),
            f(T0 + 60, Some("A320"), Some("F-GKXA")),
        ],
        None,
        &[ty("A320", "a320", "Airbus"), ty("a320", "b777", "Boeing")],
        &[fact(" F-GKXA", Some(1_635_508_800))],
        AS_OF,
    );
    assert_eq!(s.total_types, 1);
    assert_eq!(s.manufacturers.len(), 1);
    assert_eq!(
        (s.manufacturers[0].key.as_str(), s.manufacturers[0].percent),
        ("Airbus", 100)
    );
    assert_eq!(s.tails.len(), 1);
    assert_eq!(s.tails[0].flights, 2);
    assert_eq!(s.median_age_months, Some(60));
}
