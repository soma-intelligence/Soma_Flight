use flightcore::passport::{PassportStats, PastFlight, PastFlightStatus, compute_passport};

fn f(
    departed_at: i64,
    tz: &str,
    o: &str,
    d: &str,
    km: u32,
    status: PastFlightStatus,
) -> PastFlight {
    PastFlight {
        departed_at,
        tz: tz.into(),
        ident: "XX1".into(),
        origin_icao: o.into(),
        destination_icao: d.into(),
        airline: Some("AA".into()),
        aircraft_type: Some("B738".into()),
        distance_km: km,
        block_minutes: Some(60),
        delay_minutes: 0,
        status,
        origin_country: None,
        destination_country: None,
        air_minutes: None,
        registration: None,
        seat_class: None,
        seat: None,
        reason: None,
    }
}

#[test]
fn empty_is_all_zero() {
    let s = compute_passport(&[], None);
    assert_eq!(s.flights, 0);
    assert_eq!(s.avg_delay_minutes, 0);
    assert!(s.most_flown_aircraft.is_none());
    assert!(s.routes.is_empty());
}

#[test]
fn canceled_excluded_and_long_haul() {
    use PastFlightStatus::*;
    let v = vec![
        f(1_700_000_000, "UTC", "A", "B", 4000, Completed),
        f(1_700_100_000, "UTC", "B", "C", 3999, Diverted),
        f(1_700_200_000, "UTC", "C", "D", 9000, Canceled),
    ];
    let s: PassportStats = compute_passport(&v, None);
    assert_eq!(
        (s.flights, s.long_haul, s.distance_km, s.airports),
        (2, 1, 7999, 3)
    );
}

#[test]
fn la_new_year_eve_counts_in_2025() {
    // 2026-01-01T07:30Z is 2025-12-31 23:30 in Los Angeles.
    let v = vec![f(
        1_767_252_600,
        "America/Los_Angeles",
        "A",
        "B",
        10,
        PastFlightStatus::Completed,
    )];
    assert_eq!(compute_passport(&v, Some(2025)).flights, 1);
    assert_eq!(compute_passport(&v, Some(2026)).flights, 0);
}

#[test]
fn unknown_tz_is_utc_no_panic() {
    let v = vec![f(
        1_767_252_600,
        "Mars/Olympus",
        "A",
        "B",
        10,
        PastFlightStatus::Completed,
    )];
    assert_eq!(compute_passport(&v, Some(2026)).flights, 1);
}
