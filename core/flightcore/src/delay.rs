//! Delay statistics over an airport board. Pure: no clock, times are arguments.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FlightStatus {
    Scheduled,
    Departed,
    EnRoute,
    Landed,
    Arrived,
    Canceled,
    Diverted,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BoardFlight {
    pub ident: String,
    pub operator: Option<String>,
    /// Destination for departures, origin for arrivals.
    pub other_icao: String,
    pub status: FlightStatus,
    pub scheduled: Option<i64>,
    pub estimated: Option<i64>,
    pub actual: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HourBucket {
    pub hour: i64,
    pub on_time: u32,
    pub late15: u32,
    pub late45: u32,
    pub canceled: u32,
    pub diverted: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteStat {
    pub icao: String,
    pub delayed: u32,
    pub canceled: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AirlineStat {
    pub operator: String,
    pub delayed: u32,
    pub canceled: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Normal,
    Moderate,
    Major,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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

const HOUR: i64 = 3600;
const LATE15_S: i64 = 15 * 60;
const LATE45_S: i64 = 45 * 60;
const TOP: usize = 5;

fn delay_seconds(r: &BoardFlight) -> Option<i64> {
    let sched = r.scheduled?;
    let t = r.actual.or(r.estimated)?;
    Some((t - sched).max(0))
}

fn top<T>(map: BTreeMap<String, (u32, u32)>, make: impl Fn(String, u32, u32) -> T) -> Vec<T> {
    let mut v: Vec<_> = map.into_iter().filter(|(_, (d, c))| d + c > 0).collect();
    // BTreeMap iterates keys ascending and sort_by is stable: ties stay by name.
    v.sort_by_key(|a| std::cmp::Reverse(a.1.0 + a.1.1));
    v.into_iter()
        .take(TOP)
        .map(|(k, (d, c))| make(k, d, c))
        .collect()
}

pub fn compute_stats(rows: &[BoardFlight]) -> DelayStats {
    let mut buckets: BTreeMap<i64, HourBucket> = BTreeMap::new();
    let mut routes: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    let mut airlines: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    let (mut on_time, mut delayed15, mut canceled) = (0u32, 0u32, 0u32);
    let (mut sum_s, mut n_avg) = (0i64, 0i64);

    for r in rows {
        let Some(sched) = r.scheduled else { continue };
        let hour = sched.div_euclid(HOUR) * HOUR;
        let b = buckets.entry(hour).or_insert(HourBucket {
            hour,
            on_time: 0,
            late15: 0,
            late45: 0,
            canceled: 0,
            diverted: 0,
        });
        let mut bump = |is_delay: bool| {
            let slot = routes.entry(r.other_icao.clone()).or_default();
            if is_delay {
                slot.0 += 1
            } else {
                slot.1 += 1
            }
            if let Some(op) = &r.operator {
                let slot = airlines.entry(op.clone()).or_default();
                if is_delay { slot.0 += 1 } else { slot.1 += 1 }
            }
        };
        match r.status {
            FlightStatus::Canceled => {
                b.canceled += 1;
                canceled += 1;
                bump(false);
            }
            FlightStatus::Diverted => b.diverted += 1,
            _ => {
                let d = delay_seconds(r);
                if let Some(d) = d {
                    sum_s += d;
                    n_avg += 1;
                }
                match d {
                    Some(d) if d >= LATE45_S => {
                        b.late45 += 1;
                        delayed15 += 1;
                        bump(true);
                    }
                    Some(d) if d >= LATE15_S => {
                        b.late15 += 1;
                        delayed15 += 1;
                        bump(true);
                    }
                    _ => {
                        b.on_time += 1;
                        on_time += 1;
                    }
                }
            }
        }
    }

    let total = rows.len() as u32;
    let avg_delay_minutes = if n_avg > 0 {
        sum_s as f64 / n_avg as f64 / 60.0
    } else {
        0.0
    };
    // Integer comparisons keep the thresholds exact.
    let severity = if (n_avg > 0 && sum_s >= LATE45_S * n_avg)
        || (total > 0 && canceled as u64 * 10 >= total as u64)
    {
        Severity::Major
    } else if n_avg > 0 && sum_s >= LATE15_S * n_avg {
        Severity::Moderate
    } else {
        Severity::Normal
    };

    DelayStats {
        total,
        on_time,
        delayed15,
        canceled,
        avg_delay_minutes,
        per_hour: buckets.into_values().collect(),
        worst_routes: top(routes, |icao, delayed, canceled| RouteStat {
            icao,
            delayed,
            canceled,
        }),
        worst_airlines: top(airlines, |operator, delayed, canceled| AirlineStat {
            operator,
            delayed,
            canceled,
        }),
        severity,
    }
}
