//! Runs every correlate scenario vector (packs/correlate-*/vectors) and every correlate
//! load vector (spec/correlate-load-vectors) with the comparison of
//! spec/vector-format.md; a failure prints the vector and the path of its
//! first mismatch.

mod common;

use common::compare;
use goat_correlator::correlate::Engine;
use goat_correlator::json;

#[test]
fn scenario_vectors() {
    common::scenario_vectors::<Engine>("correlate-");
}

#[test]
fn load_vectors() {
    common::load_vectors::<Engine>();
}

#[test]
fn shipped_packs_load() {
    common::shipped_packs_load::<Engine>("correlate-");
}

#[test]
fn comparison_rules() {
    let p = |s: &str| json::parse(s).unwrap();
    assert!(compare(&p("1"), &p("1.0000005"), "$").is_ok());
    assert!(compare(&p("1000"), &p("1000.002"), "$").is_err());
    assert!(compare(&p("1000"), &p("1000.0009"), "$").is_ok());
    assert!(compare(&p(r#"{"a":null}"#), &p("{}"), "$").is_err());
    assert!(compare(&p("{}"), &p(r#"{"a":null}"#), "$").is_err());
    assert!(compare(&p("[1,2]"), &p("[1]"), "$").is_err());
    assert!(compare(&p(r#""A""#), &p(r#""a""#), "$").is_err());
    assert!(compare(&p("0"), &p("false"), "$").is_err());
    assert_eq!(compare(&p(r#"{"x":[1,{"y":2}]}"#), &p(r#"{"x":[1,{"y":3}]}"#), "$").unwrap_err(), "$.x[1].y: got 2, want 3");
}
