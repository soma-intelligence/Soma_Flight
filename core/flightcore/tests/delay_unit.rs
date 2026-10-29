use flightcore::delay::{BoardFlight, FlightStatus, Severity, compute_stats};
use flightcore::weather::{FlightCategory, flight_category};

fn row(status: FlightStatus, sched: i64, delay_min: i64) -> BoardFlight {
    BoardFlight {
        ident: "X1".into(),
        operator: Some("AAL".into()),
        other_icao: "KJFK".into(),
        status,
        scheduled: Some(sched),
        estimated: None,
        actual: Some(sched + delay_min * 60),
    }
}

#[test]
fn ten_departures() {
    let mut rows = vec![];
    for _ in 0..5 {
        rows.push(row(FlightStatus::Departed, 0, 0));
    }
    for _ in 0..3 {
        rows.push(row(FlightStatus::Departed, 3600, 20));
    }
    rows.push(row(FlightStatus::Departed, 3600, 50));
    let mut c = row(FlightStatus::Canceled, 7200, 0);
    c.actual = None;
    rows.push(c);
    let s = compute_stats(&rows);
    assert_eq!((s.total, s.on_time, s.delayed15, s.canceled), (10, 5, 4, 1));
    let sum: u32 = s
        .per_hour
        .iter()
        .map(|b| b.on_time + b.late15 + b.late45 + b.canceled + b.diverted)
        .sum();
    assert_eq!(sum, 10);
    // 1 of 10 canceled is 10%, which is Major by the global rule.
    assert_eq!(s.severity, Severity::Major);
}

#[test]
fn empty_is_zero_not_nan() {
    let s = compute_stats(&[]);
    assert_eq!(s.total, 0);
    assert_eq!(s.avg_delay_minutes, 0.0);
    assert_eq!(s.severity, Severity::Normal);
}

#[test]
fn early_counts_on_time() {
    let s = compute_stats(&[row(FlightStatus::Departed, 1000, -10)]);
    assert_eq!((s.on_time, s.delayed15, s.avg_delay_minutes), (1, 0, 0.0));
}

#[test]
fn unknown_status_deserializes() {
    let s: FlightStatus = serde_json::from_str("\"holding\"").unwrap();
    assert_eq!(s, FlightStatus::Unknown);
    let e: FlightStatus = serde_json::from_str("\"en_route\"").unwrap();
    assert_eq!(e, FlightStatus::EnRoute);
}

#[test]
fn categories() {
    assert_eq!(flight_category(None, 10.0), FlightCategory::Vfr);
    assert_eq!(flight_category(Some(800), 10.0), FlightCategory::Ifr);
    assert_eq!(flight_category(Some(2500), 10.0), FlightCategory::Mvfr);
    assert_eq!(flight_category(Some(300), 0.5), FlightCategory::Lifr);
    assert_eq!(flight_category(Some(1000), 3.0), FlightCategory::Mvfr);
    assert_eq!(
        serde_json::to_string(&FlightCategory::Lifr).unwrap(),
        "\"LIFR\""
    );
}
