//! Deno/WASM binding over `flightcore`. JSON strings in, JSON strings out.
//! Malformed input yields `{"error":"..."}`, never a panic.

use flightcore::delay::{BoardFlight, compute_stats};
use flightcore::geo::{Coord, MAX_SEGMENTS, distance_km, great_circle};
use flightcore::passport::{PastFlight, compute_passport};
use flightcore::passport_detail::{CountryInfo, compute_passport_detail};
use flightcore::weather::flight_category;
use serde::{Serialize, de::DeserializeOwned};
use wasm_bindgen::prelude::*;

fn error_json(msg: &str) -> String {
    serde_json::json!({ "error": msg }).to_string()
}

fn parse<T: DeserializeOwned>(what: &str, json: &str) -> Result<T, String> {
    serde_json::from_str(json).map_err(|e| format!("invalid {what}: {e}"))
}

fn encode<T: Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_else(|e| error_json(&format!("encode failed: {e}")))
}

fn finish<T: Serialize>(r: Result<T, String>) -> String {
    match r {
        Ok(v) => encode(&v),
        Err(e) => error_json(&e),
    }
}

/// Haversine distance. Throws a JS `Error` on malformed input.
#[wasm_bindgen(js_name = distanceKm)]
pub fn distance_km_js(a_json: &str, b_json: &str) -> Result<f64, JsError> {
    let a: Coord = parse("coord a", a_json).map_err(|e| JsError::new(&e))?;
    let b: Coord = parse("coord b", b_json).map_err(|e| JsError::new(&e))?;
    Ok(distance_km(a, b))
}

#[wasm_bindgen(js_name = greatCircle)]
pub fn great_circle_js(a_json: &str, b_json: &str, segments: u32) -> String {
    finish((|| {
        if segments > MAX_SEGMENTS {
            return Err(format!("segments {segments} exceeds {MAX_SEGMENTS}"));
        }
        let a: Coord = parse("coord a", a_json)?;
        let b: Coord = parse("coord b", b_json)?;
        Ok(great_circle(a, b, segments))
    })())
}

#[wasm_bindgen(js_name = computeStats)]
pub fn compute_stats_js(rows_json: &str) -> String {
    finish(parse::<Vec<BoardFlight>>("rows", rows_json).map(|r| compute_stats(&r)))
}

#[wasm_bindgen(js_name = flightCategory)]
pub fn flight_category_js(ceiling_ft: Option<i32>, visibility_sm: f64) -> String {
    encode(&flight_category(ceiling_ft, visibility_sm))
}

#[wasm_bindgen(js_name = computePassport)]
pub fn compute_passport_js(flights_json: &str, year: Option<i32>) -> String {
    finish(parse::<Vec<PastFlight>>("flights", flights_json).map(|f| compute_passport(&f, year)))
}

#[wasm_bindgen(js_name = computePassportDetail)]
pub fn compute_passport_detail_js(
    flights_json: &str,
    year: Option<i32>,
    countries_json: &str,
) -> String {
    finish((|| {
        let flights: Vec<PastFlight> = parse("flights", flights_json)?;
        let countries: Vec<CountryInfo> = parse("countries", countries_json)?;
        Ok(compute_passport_detail(&flights, year, &countries))
    })())
}
