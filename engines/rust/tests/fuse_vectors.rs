//! Runs every fuse scenario vector (packs/fuse-*/vectors) and every fuse
//! load vector (spec/fuse-load-vectors) with the comparison of
//! spec/vector-format.md; a failure prints the vector and the path of its
//! first mismatch.

mod common;

use goat_correlator::fuse::Engine;

#[test]
fn fuse_scenario_vectors() {
    common::scenario_vectors::<Engine>("fuse-");
}

#[test]
fn fuse_load_vectors() {
    common::load_vectors::<Engine>();
}

#[test]
fn fuse_shipped_packs_load() {
    common::shipped_packs_load::<Engine>("fuse-");
}
