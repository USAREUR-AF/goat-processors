//! Runs every correlate scenario vector (packs/correlate-*) and every correlate
//! load vector (spec/correlate-load-vectors) (spec/vector-format.md).

mod common;

use std::path::Path;

use common::{compare, json_files, packs_with_prefix, read_json, repo_root};
use goat_correlator::{json, load_pack, parse_pack, Engine, Json};

/// Runs one scenario vector; the first mismatch, if any.
fn run_scenario(root: &Path, path: &Path) -> Result<(), String> {
    let v = read_json(path);
    let pack_name = v.get("pack").and_then(Json::as_str).ok_or("vector has no pack")?;
    let pack = load_pack(&root.join("packs").join(pack_name))?;
    let mut engine = Engine::new(pack);
    let steps = v.get("steps").and_then(Json::as_array).ok_or("vector has no steps")?;
    for (i, step) in steps.iter().enumerate() {
        let result = match (step.get("ingest"), step.get("tick")) {
            (Some(report), None) => engine.ingest(report),
            (None, Some(t)) => engine.tick(t.as_i64().ok_or("tick is not an integer")?),
            _ => return Err(format!("steps[{}]: needs exactly one of ingest or tick", i)),
        };
        compare(&Json::Arr(result.events), step.get("expect").ok_or("step has no expect")?, &format!("steps[{}].expect", i))?;
        compare(&Json::Arr(result.trace), step.get("trace").ok_or("step has no trace")?, &format!("steps[{}].trace", i))?;
    }
    compare(&engine.snapshot(), v.get("snapshot").ok_or("vector has no snapshot")?, "snapshot")
}

#[test]
fn scenario_vectors() {
    let root = repo_root();
    // Correlate vectors only: packs/correlate-*.
    let packs = packs_with_prefix(&root, "correlate-");
    let mut ran = 0;
    let mut failures = Vec::new();
    for pack in packs {
        for path in json_files(&pack.join("vectors")) {
            ran += 1;
            let name = path.strip_prefix(&root).unwrap().display().to_string();
            match run_scenario(&root, &path) {
                Ok(()) => println!("ok   {}", name),
                Err(e) => {
                    println!("FAIL {}: {}", name, e);
                    failures.push(format!("{}: {}", name, e));
                }
            }
        }
    }
    assert!(ran > 0, "no scenario vectors found");
    assert!(failures.is_empty(), "{} of {} scenario vectors failed:\n{}", failures.len(), ran, failures.join("\n"));
}

#[test]
fn load_vectors() {
    let root = repo_root();
    let mut ran = 0;
    let mut failures = Vec::new();
    for path in json_files(&root.join("spec/correlate-load-vectors")) {
        ran += 1;
        let v = read_json(&path);
        let name = v.get("name").and_then(Json::as_str).unwrap_or("?").to_string();
        let text = v.get("pack_def").and_then(Json::as_str).expect("load vector has no pack_def");
        let expect_error = matches!(v.get("expect_error"), Some(Json::Bool(true)));
        let result = parse_pack(text);
        match (expect_error, &result) {
            (true, Err(e)) => println!("ok   {} (error: {})", name, e),
            (false, Ok(_)) => println!("ok   {}", name),
            (true, Ok(_)) => failures.push(format!("{}: loaded, want an error", name)),
            (false, Err(e)) => failures.push(format!("{}: error {}, want success", name, e)),
        }
    }
    assert!(ran > 0, "no load vectors found");
    assert!(failures.is_empty(), "{} of {} load vectors failed:\n{}", failures.len(), ran, failures.join("\n"));
}

#[test]
fn shipped_packs_load() {
    let root = repo_root();
    let packs = packs_with_prefix(&root, "correlate-");
    assert!(!packs.is_empty(), "no correlate packs found");
    for dir in packs {
        load_pack(&dir).unwrap_or_else(|e| panic!("{}: {}", dir.display(), e));
    }
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
