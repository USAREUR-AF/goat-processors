//! The data model every function shares: JSON values, reports, the local
//! plane, the per-axis track estimate, the two-model filter, and the pack
//! values more than one function reads. Everything here is a value or a pure
//! function; no state.

pub mod frame;
pub mod json;
pub mod pack;
pub mod report;
pub mod track;
pub mod two_model;

pub use frame::{deg, rad, wrap180, Frame, R};
pub use json::{obj, Json};
pub use track::{measurement_variance, velocity, Axis, Innovation, Measurement, MeasurementVariance, Model};
pub use two_model::{ModeUpdate, TwoModel};
