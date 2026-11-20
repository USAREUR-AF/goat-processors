//! Acceptance: every scenario vector of every pack, replayed through the
//! runner binary (`goat-processors replay <vector> --trace --snapshot`), gives
//! the vector's events and trace at every step and its final snapshot,
//! compared as spec/vector-format.md states.

use std::path::{Path, PathBuf};
use std::process::Command;

use goat_correlator::json::{self, Json};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap()
}

fn compare(got: &Json, want: &Json, path: &str) -> Result<(), String> {
    let bad = || Err(format!("{path}: got {got}, want {want}"));
    match (got, want) {
        (Json::Num(_) | Json::Int(_), Json::Num(_) | Json::Int(_)) => {
            let (g, w) = (got.as_f64().unwrap(), want.as_f64().unwrap());
            if (g - w).abs() <= 1e-6 * w.abs().max(1.0) { Ok(()) } else { bad() }
        }
        (Json::Arr(g), Json::Arr(w)) => {
            if g.len() != w.len() {
                return bad();
            }
            for (i, (a, b)) in g.iter().zip(w).enumerate() {
                compare(a, b, &format!("{path}[{i}]"))?;
            }
            Ok(())
        }
        (Json::Obj(g), Json::Obj(w)) => {
            if g.keys().ne(w.keys()) {
                return bad();
            }
            for (k, v) in w {
                compare(&g[k], v, &format!("{path}.{k}"))?;
            }
            Ok(())
        }
        _ => if got == want { Ok(()) } else { bad() },
    }
}

fn vectors() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for pack in std::fs::read_dir(repo().join("packs")).unwrap() {
        let dir = pack.unwrap().path().join("vectors");
        if let Ok(rd) = std::fs::read_dir(&dir) {
            out.extend(rd.map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "json")));
        }
    }
    out.sort();
    out
}

#[test]
fn every_vector_replays_exactly() {
    let bin = env!("CARGO_BIN_EXE_goat-processors");
    let files = vectors();
    assert!(files.len() > 100, "found only {} vectors", files.len());
    let mut failures = Vec::new();
    for v in &files {
        let want = json::parse(&std::fs::read_to_string(v).unwrap()).unwrap();
        let function = want.get("pack").and_then(|p| p.as_str()).unwrap().split('-').next().unwrap().to_string();
        let out = Command::new(bin)
            .arg("replay")
            .arg(v)
            .args(["--trace", "--snapshot", "--packs-dir"])
            .arg(repo().join("packs"))
            .output()
            .unwrap();
        let name = v.strip_prefix(repo()).unwrap().display().to_string();
        if !out.status.success() {
            failures.push(format!("{name}: exit {}: {}", out.status, String::from_utf8_lossy(&out.stderr)));
            continue;
        }
        let lines: Vec<Json> = String::from_utf8(out.stdout).unwrap().lines().map(|l| json::parse(l).unwrap()).collect();
        let steps = want.get("steps").and_then(|s| s.as_array()).unwrap();
        let check = || -> Result<(), String> {
            if lines.len() != steps.len() + 1 {
                return Err(format!("{} output lines for {} steps", lines.len(), steps.len()));
            }
            for (i, (got, step)) in lines.iter().zip(steps).enumerate() {
                compare(got.get("stage").unwrap(), &Json::Str(function.clone()), &format!("steps[{i}].stage"))?;
                compare(got.get("events").unwrap(), step.get("expect").unwrap(), &format!("steps[{i}].expect"))?;
                compare(got.get("trace").unwrap(), step.get("trace").unwrap(), &format!("steps[{i}].trace"))?;
            }
            let snap = lines.last().unwrap().get("snapshot").and_then(|s| s.get(&function)).ok_or("no snapshot line")?;
            compare(snap, want.get("snapshot").unwrap(), "snapshot")
        };
        if let Err(e) = check() {
            failures.push(format!("{name}: {e}"));
        }
    }
    eprintln!("{} vectors replayed, {} failed", files.len(), failures.len());
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
