//! Runs every filter scenario vector (packs/filter-*/vectors) and every filter
//! load vector (spec/filter-load-vectors) with the comparison of
//! spec/vector-format.md; a failure prints the vector and the path of its
//! first mismatch.

mod common;

use goat_correlator::filter::Engine;

#[test]
fn filter_scenario_vectors() {
    common::scenario_vectors::<Engine>("filter-");
}

#[test]
fn filter_load_vectors() {
    common::load_vectors::<Engine>();
}

#[test]
fn filter_shipped_packs_load() {
    common::shipped_packs_load::<Engine>("filter-");
}
