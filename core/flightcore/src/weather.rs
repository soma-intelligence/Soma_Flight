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
pub fn flight_category(ceiling_ft: Option<i32>, visibility_sm: f64) -> FlightCategory {
    let ceiling = ceiling_ft.map_or(i64::MAX, i64::from);
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
