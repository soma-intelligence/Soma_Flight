//! Pure flight logic shared by edge functions (WASM) and the Swift apps (UniFFI).
//! No I/O, no network, no clock reads.

pub mod aircraft;
pub mod delay;
pub mod geo;
pub mod impact;
pub mod passport;
pub mod passport_detail;
pub mod predict;
pub mod weather;
