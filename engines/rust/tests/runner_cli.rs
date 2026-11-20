//! The runner binary as tools/perf/README.md "Runner contract" states: one
//! counters line on standard output, the events file, and a non-zero exit
//! with a message on standard error for a bad function, pack or steps file.

mod common;

use std::process::Command;

use goat_correlator::{json, Json};

fn runner(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_runner")).args(args).output().unwrap()
}

#[test]
fn counters_and_events() {
    let root = common::repo_root();
    let pack = root.join("packs/quality-feed");
    let steps = common::json_files(&pack.join("vectors")).remove(0);
    let events = std::env::temp_dir().join(format!("goat-runner-cli-{}.jsonl", std::process::id()));
    let out = runner(&[
        "--function", "quality", "--pack", pack.to_str().unwrap(), "--steps", steps.to_str().unwrap(), "--events", events.to_str().unwrap(),
    ]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 1);
    let counters = json::parse(stdout.trim()).unwrap();
    for key in ["engine", "function", "pack", "steps", "ingest", "tick", "events", "trace_records", "parse_ns", "load_ns", "run_ns"] {
        assert!(counters.get(key).is_some(), "no {}", key);
    }
    assert_eq!(counters.get("function"), Some(&Json::from("quality")));
    let text = std::fs::read_to_string(&events).unwrap();
    let first = json::parse(text.lines().next().unwrap()).unwrap();
    assert!(first.get("trace").is_none(), "no --trace, no trace");
    std::fs::remove_file(events).unwrap();
}

#[test]
fn failures_exit_non_zero_with_a_message() {
    let root = common::repo_root();
    let pack = root.join("packs/fuse-best");
    let steps = common::json_files(&pack.join("vectors")).remove(0);
    for args in [
        vec!["--function", "nothing", "--pack", pack.to_str().unwrap(), "--steps", steps.to_str().unwrap()],
        vec!["--function", "fuse", "--pack", "/nonexistent", "--steps", steps.to_str().unwrap()],
        vec!["--function", "fuse", "--pack", pack.to_str().unwrap(), "--steps", "/nonexistent.json"],
        vec!["--function", "fuse"],
    ] {
        let out = runner(&args);
        assert!(!out.status.success(), "{:?}", args);
        assert!(out.stdout.is_empty() && !out.stderr.is_empty(), "{:?}", args);
    }
}
