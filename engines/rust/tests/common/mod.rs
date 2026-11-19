//! Shared by the correlate and fuse vector runners: the structural comparison
//! of spec/vector-format.md and file helpers.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use goat_correlator::{json, Json};

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
