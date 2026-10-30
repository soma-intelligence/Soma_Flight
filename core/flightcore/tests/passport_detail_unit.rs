use flightcore::passport::{PastFlight, PastFlightStatus};
use flightcore::passport_detail::{
    CONNECTION_SECONDS, CountryInfo, Region, airport_visits, compute_passport_detail,
};

fn f(departed_at: i64, o: &str, d: &str, block: Option<u32>) -> PastFlight {
    PastFlight {
        departed_at,
        tz: "UTC".into(),
        ident: "XX1".into(),
        origin_icao: o.into(),
        destination_icao: d.into(),
        airline: Some("AAL".into()),
        aircraft_type: None,
        distance_km: 500,
        block_minutes: block,
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
    }
}

fn visits(flights: &[PastFlight]) -> Vec<(String, u32)> {
    let refs: Vec<&PastFlight> = flights.iter().collect();
    airport_visits(&refs)
        .into_iter()
        .map(|v| (v.icao, v.visits))
        .collect()
}

const T0: i64 = 1_750_000_000;

#[test]
fn connection_just_under_eight_hours_counts_once() {
    // Lands T0 + 1 h, departs again 7 h 59 min 59 s later.
    let v = visits(&[
        f(T0, "AAAA", "BBBB", Some(60)),
        f(T0 + 3600 + CONNECTION_SECONDS - 1, "BBBB", "CCCC", Some(60)),
    ]);
    assert_eq!(
        v,
        [("AAAA".into(), 1), ("BBBB".into(), 1), ("CCCC".into(), 1)]
    );
}

#[test]
fn stop_of_exactly_eight_hours_counts_twice() {
    let v = visits(&[
        f(T0, "AAAA", "BBBB", Some(60)),
        f(T0 + 3600 + CONNECTION_SECONDS, "BBBB", "CCCC", Some(60)),
    ]);
    assert_eq!(
        v,
        [("BBBB".into(), 2), ("AAAA".into(), 1), ("CCCC".into(), 1)]
    );
}

#[test]
fn missing_block_measures_from_previous_departure() {
    let v = visits(&[
        f(T0, "AAAA", "BBBB", None),
        f(T0 + CONNECTION_SECONDS - 1, "BBBB", "CCCC", None),
    ]);
    assert_eq!(
        v,
        [("AAAA".into(), 1), ("BBBB".into(), 1), ("CCCC".into(), 1)]
    );
}

#[test]
fn different_airport_is_never_a_connection() {
    let v = visits(&[
        f(T0, "AAAA", "BBBB", Some(60)),
        f(T0 + 7200, "CCCC", "DDDD", Some(60)),
    ]);
    assert_eq!(v.iter().map(|(_, n)| n).sum::<u32>(), 4);
}

#[test]
fn round_trip_home_counts_home_twice() {
    // Out and back the same day: home is a visit at both ends.
    let v = visits(&[
        f(T0, "HOME", "AWAY", Some(60)),
        f(T0 + 7200, "AWAY", "HOME", Some(60)),
    ]);
    assert_eq!(v, [("HOME".into(), 2), ("AWAY".into(), 1)]);
}

#[test]
fn empty_has_no_division_by_zero() {
    let d = compute_passport_detail(&[], None, &[]);
    assert_eq!(d.flights, 0);
    assert_eq!(d.avg_distance_km, 0);
    assert_eq!(d.avg_flight_minutes, 0);
    assert_eq!(d.earth_ratio, 0.0);
    assert!(d.shortest_by_distance.is_none() && d.longest_by_time.is_none());
    assert_eq!(d.regions.len(), 9);
    assert!(d.regions.iter().all(|r| r.total == 0 && r.visited == 0));
}

#[test]
fn one_flight_is_its_own_shortest_and_longest() {
    let d = compute_passport_detail(&[f(T0, "AAAA", "BBBB", Some(90))], None, &[]);
    assert_eq!(d.shortest_by_distance, d.longest_by_distance);
    assert_eq!(d.shortest_by_time, d.longest_by_time);
    assert_eq!(d.shortest_by_distance, d.shortest_by_time);
    assert!(d.shortest_by_distance.is_some());
}

#[test]
fn split_adds_up_and_regions_follow_declaration_order() {
    let mut a = f(T0, "LFPG", "KSFO", None);
    a.origin_country = Some("FR".into());
    a.destination_country = Some("US".into());
    let mut b = f(T0 + 86_400, "KSFO", "KLAX", None);
    b.origin_country = Some("US".into());
    b.destination_country = Some("US".into());
    let c = f(T0 + 2 * 86_400, "KLAX", "XXXX", None);
    let refs = [
        CountryInfo {
            iso2: "US".into(),
            region: Region::NorthAmerica,
        },
        CountryInfo {
            iso2: "FR".into(),
            region: Region::Europe,
        },
    ];
    let d = compute_passport_detail(&[a, b, c], None, &refs);
    assert_eq!(
        (d.domestic, d.international, d.unknown_country_flights),
        (1, 1, 1)
    );
    assert_eq!(
        d.regions.iter().map(|r| r.region).collect::<Vec<_>>(),
        Region::ALL
    );
    assert_eq!((d.regions[0].visited, d.regions[1].visited), (1, 1));
    // US counts once for the domestic flight and once for the international one.
    assert_eq!(d.countries[0].iso2, "US");
    assert_eq!(d.countries[0].flights, 2);
}

#[test]
fn old_passport_input_still_parses() {
    let json = r#"[{"departed_at":1750000000,"tz":"UTC","ident":"X1","origin_icao":"A","destination_icao":"B",
        "airline":null,"aircraft_type":null,"distance_km":1,"block_minutes":null,"delay_minutes":0,"status":"completed"}]"#;
    let v: Vec<PastFlight> = serde_json::from_str(json).unwrap();
    assert!(v[0].origin_country.is_none() && v[0].seat_class.is_none());
}

#[test]
fn chain_of_connections_counts_each_stop_once() {
    // Four legs, each under 8 h on the ground: only the first origin and the destinations count.
    let v = visits(&[
        f(T0, "AAAA", "BBBB", Some(60)),
        f(T0 + 3 * 3600, "BBBB", "CCCC", Some(60)),
        f(T0 + 6 * 3600, "CCCC", "DDDD", Some(60)),
        f(T0 + 9 * 3600, "DDDD", "EEEE", Some(60)),
    ]);
    assert_eq!(v.iter().map(|(_, n)| n).sum::<u32>(), 5);
    assert!(v.iter().all(|(_, n)| *n == 1));
}

#[test]
fn country_codes_ignore_case_and_reference_duplicates() {
    let mut a = f(T0, "LFPG", "LFMN", None);
    a.origin_country = Some("fr".into());
    a.destination_country = Some(" FR ".into());
    let mut b = f(T0 + 86_400, "LFMN", "KJFK", None);
    b.origin_country = Some("FR".into());
    b.destination_country = Some("   ".into());
    let refs = [
        CountryInfo {
            iso2: "FR".into(),
            region: Region::Europe,
        },
        CountryInfo {
            iso2: "fr".into(),
            region: Region::Asia,
        },
    ];
    let d = compute_passport_detail(&[a, b], None, &refs);
    assert_eq!(
        (d.domestic, d.international, d.unknown_country_flights),
        (1, 0, 1)
    );
    assert_eq!(d.countries.len(), 1);
    assert_eq!(
        (d.countries[0].iso2.as_str(), d.countries[0].flights),
        ("FR", 2)
    );
    assert_eq!((d.regions[0].visited, d.regions[0].total), (1, 1));
    assert_eq!(d.regions[7].total, 0);
}
