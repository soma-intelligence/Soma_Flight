//! Pure flight logic shared by edge functions (WASM) and the Swift apps (UniFFI).
//! No I/O, no network, no clock reads.

pub mod delay;
pub mod geo;
pub mod weather;
