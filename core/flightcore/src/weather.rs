//! FAA flight category from ceiling and visibility.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum FlightCategory {
    Vfr,
    Mvfr,
    Ifr,
    Lifr,
}

/// `ceiling_ft` None means unlimited. Visibility in statute miles.
/// Non-finite or negative visibility is invalid data and yields the worst
/// category (LIFR), never an optimistic one.
pub fn flight_category(ceiling_ft: Option<i32>, visibility_sm: f64) -> FlightCategory {
    let ceiling = ceiling_ft.map_or(i64::MAX, i64::from);
    if !visibility_sm.is_finite() || visibility_sm < 0.0 {
        return FlightCategory::Lifr;
    }
    if ceiling < 500 || visibility_sm < 1.0 {
        FlightCategory::Lifr
    } else if ceiling < 1000 || visibility_sm < 3.0 {
        FlightCategory::Ifr
    } else if ceiling <= 3000 || visibility_sm <= 5.0 {
        FlightCategory::Mvfr
    } else {
        FlightCategory::Vfr
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_visibility_is_lifr() {
        for v in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0, -0.5] {
            assert_eq!(flight_category(None, v), FlightCategory::Lifr, "{v}");
            assert_eq!(flight_category(Some(5000), v), FlightCategory::Lifr, "{v}");
        }
        assert_eq!(flight_category(None, 0.0), FlightCategory::Lifr);
        assert_eq!(flight_category(None, 10.0), FlightCategory::Vfr);
    }
}
