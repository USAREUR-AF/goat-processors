//! Runs every quality scenario vector (packs/quality-*/vectors) and every quality
//! load vector (spec/quality-load-vectors) with the comparison of
//! spec/vector-format.md; a failure prints the vector and the path of its
//! first mismatch.

mod common;

use goat_correlator::quality::Engine;

#[test]
fn quality_scenario_vectors() {
    common::scenario_vectors::<Engine>("quality-");
}

#[test]
fn quality_load_vectors() {
    common::load_vectors::<Engine>();
}

#[test]
fn quality_shipped_packs_load() {
    common::shipped_packs_load::<Engine>("quality-");
}
