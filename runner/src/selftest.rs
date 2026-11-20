//! `goat-processors selftest`: replays every scenario vector found under the
//! packs directory through the pipeline code the service runs, and compares
//! each step's events and trace and the final snapshot with the vector
//! (spec/vector-format.md: numbers within `1e-6 * max(1, |want|)`, a key
//! with `null` differs from an absent key). It reads no config and touches
//! nothing outside the packs directory.

use std::path::{Path, PathBuf};

use goat_correlator::json::{self, Json};

use crate::pipeline::{load_stage, Pipeline, Stage};
use crate::replay::{self, Step};

pub fn compare(got: &Json, want: &Json, path: &str) -> Result<(), String> {
    let bad = || Err(format!("{path}: got {got}, want {want}"));
    match (got, want) {
        (Json::Num(_) | Json::Int(_), Json::Num(_) | Json::Int(_)) => {
            let (g, w) = (got.as_f64().unwrap_or(f64::NAN), want.as_f64().unwrap_or(f64::NAN));
            if (g - w).abs() <= 1e-6 * w.abs().max(1.0) {
                Ok(())
            } else {
                bad()
            }
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
        _ if got == want => Ok(()),
        _ => bad(),
    }
}

pub fn vectors(packs_dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(packs_dir) {
        for pack in rd.flatten() {
            if let Ok(vs) = std::fs::read_dir(pack.path().join("vectors")) {
                out.extend(vs.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "json")));
            }
        }
    }
    out.sort();
    out
}

/// Checks one vector. Err holds the first difference.
pub fn check(packs_dir: &Path, vector: &Path) -> Result<(), String> {
    let text = std::fs::read_to_string(vector).map_err(|e| e.to_string())?;
    let want = json::parse(&text)?;
    let file = replay::read(&text)?;
    let pack = file.vector_pack.ok_or("the vector names no pack")?;
    let function = pack.split('-').next().unwrap_or("").to_string();
    let engine = load_stage(&function, &packs_dir.join(&pack))?;
    let mut p = Pipeline::new(vec![Stage { function: function.clone(), pack, engine }]);
    let steps = want.get("steps").and_then(|s| s.as_array()).ok_or("no steps")?;
    for (i, (step, w)) in file.steps.iter().zip(steps).enumerate() {
        let out = match step {
            Step::Ingest(r) => p.ingest(r),
            Step::Tick(t) => p.tick(*t),
        };
        let s = &out.stages[0];
        compare(&Json::Arr(s.events.clone()), w.get("expect").unwrap_or(&Json::Null), &format!("steps[{i}].expect"))?;
        compare(&Json::Arr(s.trace.clone()), w.get("trace").unwrap_or(&Json::Null), &format!("steps[{i}].trace"))?;
    }
    let snap = p.snapshot();
    compare(snap.get(&function).unwrap_or(&Json::Null), want.get("snapshot").unwrap_or(&Json::Null), "snapshot")
}

/// Runs every vector; returns (passed, failures).
pub fn run(packs_dir: &Path) -> (usize, Vec<String>) {
    let mut passed = 0;
    let mut failed = Vec::new();
    for v in vectors(packs_dir) {
        match check(packs_dir, &v) {
            Ok(()) => passed += 1,
            Err(e) => failed.push(format!("{}: {e}", v.strip_prefix(packs_dir).unwrap_or(&v).display())),
        }
    }
    (passed, failed)
}
