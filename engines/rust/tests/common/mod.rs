//! Shared by the correlate, filter, fuse and quality vector runners: file listing
//! and the structural comparison of spec/vector-format.md ("What the engine checks").
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use goat_correlator::{json, Function, Json};

pub fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

pub fn json_files(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {}", dir.display(), e))
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    files.sort();
    files
}

pub fn read_json(path: &Path) -> Json {
    let text = fs::read_to_string(path).unwrap();
    json::parse(&text).unwrap_or_else(|e| panic!("{}: {}", path.display(), e))
}

/// Structural equality; floats within 1e-6 * max(1, |want|); null differs from
/// absent. Returns the path of the first mismatch.
pub fn compare(got: &Json, want: &Json, path: &str) -> Result<(), String> {
    let mismatch = || Err(format!("{}: got {}, want {}", path, got, want));
    match (got, want) {
        (Json::Num(_) | Json::Int(_), Json::Num(_) | Json::Int(_)) => {
            let (g, w) = (got.as_f64().unwrap(), want.as_f64().unwrap());
            if (g - w).abs() <= 1e-6 * w.abs().max(1.0) {
                Ok(())
            } else {
                mismatch()
            }
        }
        (Json::Arr(g), Json::Arr(w)) => {
            if g.len() != w.len() {
                return Err(format!("{}: length {} != {}; got {}, want {}", path, g.len(), w.len(), got, want));
            }
            for (i, (gi, wi)) in g.iter().zip(w).enumerate() {
                compare(gi, wi, &format!("{}[{}]", path, i))?;
            }
            Ok(())
        }
        (Json::Obj(g), Json::Obj(w)) => {
            for k in w.keys() {
                if !g.contains_key(k) {
                    return Err(format!("{}.{}: absent, want {}", path, k, w[k]));
                }
            }
            for k in g.keys() {
                if !w.contains_key(k) {
                    return Err(format!("{}.{}: got {}, want absent", path, k, g[k]));
                }
            }
            for (k, wv) in w {
                compare(&g[k], wv, &format!("{}.{}", path, k))?;
            }
            Ok(())
        }
        (Json::Str(g), Json::Str(w)) if g == w => Ok(()),
        (Json::Bool(g), Json::Bool(w)) if g == w => Ok(()),
        (Json::Null, Json::Null) => Ok(()),
        _ => mismatch(),
    }
}

/// The `packs/<prefix>*` directories, in name order.
pub fn packs_with_prefix(root: &Path, prefix: &str) -> Vec<PathBuf> {
    let mut packs: Vec<PathBuf> = fs::read_dir(root.join("packs"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with(prefix)))
        .collect();
    packs.sort();
    packs
}

/// Runs one scenario vector through function `F`; the first mismatch, if any.
pub fn run_scenario<F: Function>(root: &Path, path: &Path) -> Result<(), String> {
    let v = read_json(path);
    let pack_name = v.get("pack").and_then(Json::as_str).ok_or("vector has no pack")?;
    let mut engine = F::new(F::load_pack(&root.join("packs").join(pack_name))?);
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

/// Every scenario vector of `packs/<prefix>*`; panics with every failure.
pub fn scenario_vectors<F: Function>(prefix: &str) {
    let root = repo_root();
    let mut ran = 0;
    let mut failures = Vec::new();
    for pack in packs_with_prefix(&root, prefix) {
        for path in json_files(&pack.join("vectors")) {
            ran += 1;
            let name = path.strip_prefix(&root).unwrap().display().to_string();
            match run_scenario::<F>(&root, &path) {
                Ok(()) => println!("ok   {}", name),
                Err(e) => {
                    println!("FAIL {}: {}", name, e);
                    failures.push(format!("{}: {}", name, e));
                }
            }
        }
    }
    assert!(ran > 0, "no {} scenario vectors found", F::NAME);
    assert!(failures.is_empty(), "{} of {} {} scenario vectors failed:\n{}", failures.len(), ran, F::NAME, failures.join("\n"));
}

/// Every load vector of `spec/<function>-load-vectors`; panics with every failure.
pub fn load_vectors<F: Function>() {
    let root = repo_root();
    let mut ran = 0;
    let mut failures = Vec::new();
    for path in json_files(&root.join(format!("spec/{}-load-vectors", F::NAME))) {
        ran += 1;
        let v = read_json(&path);
        let name = v.get("name").and_then(Json::as_str).unwrap_or("?").to_string();
        let text = v.get("pack_def").and_then(Json::as_str).expect("load vector has no pack_def");
        let expect_error = matches!(v.get("expect_error"), Some(Json::Bool(true)));
        match (expect_error, F::parse_pack(text)) {
            (true, Err(e)) => println!("ok   {} (error: {})", name, e),
            (false, Ok(_)) => println!("ok   {}", name),
            (true, Ok(_)) => failures.push(format!("{}: loaded, want an error", name)),
            (false, Err(e)) => failures.push(format!("{}: error {}, want success", name, e)),
        }
    }
    assert!(ran > 0, "no {} load vectors found", F::NAME);
    assert!(failures.is_empty(), "{} of {} {} load vectors failed:\n{}", failures.len(), ran, F::NAME, failures.join("\n"));
}

/// Every shipped `packs/<prefix>*` loads.
pub fn shipped_packs_load<F: Function>(prefix: &str) {
    let packs = packs_with_prefix(&repo_root(), prefix);
    assert!(!packs.is_empty(), "no {} packs found", F::NAME);
    for dir in packs {
        F::load_pack(&dir).unwrap_or_else(|e| panic!("{}: {}", dir.display(), e));
    }
}
