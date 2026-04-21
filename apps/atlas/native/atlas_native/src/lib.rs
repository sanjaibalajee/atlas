//! Atlas native code.
//!
//! Exposes BLAKE3 hashing and FastCDC content-defined chunking to the BEAM
//! through Rustler. All I/O-bound or CPU-heavy functions are marked with
//! dirty schedulers so they never block the regular BEAM schedulers.

mod chunking;
mod hashing;

rustler::init!("Elixir.Atlas.Native");
