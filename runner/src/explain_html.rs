//! A replay as one self-contained HTML page: the `tools/explain` viewer
//! (plan, step slider, input, events, trace, the stage's state after every
//! step, and the pack's rules), filled from the runner's own pipeline.
//!
//! It builds the same data `tools/explain/explain.py` builds for a vector,
//! for one stage of the pipeline, so the page reads the same. The viewer is
//! built into the binary; the page loads nothing from anywhere.

use std::collections::VecDeque;

use crate::json::Json;
use crate::pipeline::Pipeline;
use crate::replay::{self, Done, ReplayFile, Step};

const VIEWER: &str = include_str!("../../tools/explain/viewer.html");

/// The most steps one page holds; a longer replay keeps its last steps.
pub const MAX_STEPS: usize = 3000;

const R: f64 = 6371008.8;

/// Brings a longitude difference into (-180, 180], in bounded time.
fn wrap180(x: f64) -> f64 {
    let r = (x + 180.0).rem_euclid(360.0) - 180.0;
    if r == -180.0 {
        180.0
    } else {
        r
    }
}

fn to_plane(r: (f64, f64), lat: f64, lon: f64) -> (f64, f64) {
    (R * wrap180(lon - r.1).to_radians() * r.0.to_radians().cos(), R * (lat - r.0).to_radians())
}

fn num(v: Option<&Json>) -> Option<f64> {
    v.and_then(Json::as_f64)
}

fn arr(v: Vec<Json>) -> Json {
    Json::Arr(v)
}

fn obj(pairs: Vec<(&str, Json)>) -> Json {
    let mut m = crate::json::Map::new();
    for (k, v) in pairs {
        m.insert(k.to_string().into(), v);
    }
    Json::Obj(m)
}

/// entity -> [east, north, sigma east, sigma north, time, velocity east,
/// velocity north], from a snapshot's filters (as `explain.py` estimates).
fn estimates(snap: &Json) -> Json {
    let mut out = crate::json::Map::new();
    if let Some(Json::Obj(ents)) = snap.get("entities") {
        for (k, e) in ents {
            let Some(f) = e.get("filter") else { continue };
            let (Some(Json::Arr(ea)), Some(Json::Arr(no))) = (f.get("east"), f.get("north")) else { continue };
            let g = |a: &Vec<Json>, i: usize| a.get(i).and_then(Json::as_f64).unwrap_or(0.0);
            if ea.len() < 3 || no.len() < 3 {
                continue;
            }
            out.insert(
                k.clone(),
                arr(vec![
                    Json::Num(g(ea, 0)),
                    Json::Num(g(no, 0)),
                    Json::Num(g(ea, 2).max(0.0).sqrt()),
                    Json::Num(g(no, 2).max(0.0).sqrt()),
                    e.get("last_time_ms").cloned().unwrap_or(Json::Null),
                    Json::Num(g(ea, 1)),
                    Json::Num(g(no, 1)),
                ]),
            );
        }
    }
    Json::Obj(out)
}

/// ("group" | "system", id -> members) from a snapshot.
fn clusters(snap: &Json) -> (Json, Json) {
    for (kind, key) in [("group", "groups"), ("system", "systems")] {
        if let Some(c @ Json::Obj(_)) = snap.get(key) {
            return (Json::Str(kind.into()), c.clone());
        }
    }
    (Json::Null, Json::Obj(crate::json::Map::new()))
}

/// JSON has no infinity or NaN: write them as strings, as `explain.py` does.
fn finite(v: &Json) -> Json {
    match v {
        Json::Num(x) if x.is_nan() => Json::Str("nan".into()),
        Json::Num(x) if x.is_infinite() => Json::Str(if *x > 0.0 { "inf" } else { "-inf" }.into()),
        Json::Arr(a) => Json::Arr(a.iter().map(finite).collect()),
        Json::Obj(m) => Json::Obj(m.iter().map(|(k, x)| (k.clone(), finite(x))).collect()),
        other => other.clone(),
    }
}

fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// What one page shows.
pub struct Page {
    pub name: String,
    pub file: String,
    /// Names to call out in the note (a track and its members).
    pub focus: Vec<String>,
}

/// Replays `file` through `p` and returns the page for its `stage` stage.
pub fn render(p: &mut Pipeline, file: &ReplayFile, tick_ms: i64, packs_dir: &std::path::Path, stage: &str, page: &Page) -> Result<String, String> {
    let si = p.stages.iter().position(|s| s.function == stage).ok_or_else(|| {
        format!("the pipeline has no {stage} stage; it has {}", p.stages.iter().map(|s| s.function.as_str()).collect::<Vec<_>>().join(", "))
    })?;
    let pack = p.stages[si].pack.clone();
    // (step number, step, events, trace, snapshot of the stage after it)
    let mut kept: VecDeque<(usize, Step, Vec<Json>, Vec<Json>, Json)> = VecDeque::new();
    let mut total = 0usize;
    replay::run_steps(p, file, tick_ms, packs_dir, |n, step, done, p| {
        let Done::Output(out) = done else { return };
        total += 1;
        let (ev, tr) = out.stages.iter().find(|s| s.function == stage).map(|s| (s.events.clone(), s.trace.clone())).unwrap_or_default();
        let snap = p.stages.iter().find(|s| s.function == stage).map(|s| s.engine.snapshot()).unwrap_or(Json::Null);
        kept.push_back((n, step.clone(), ev, tr, snap));
        if kept.len() > MAX_STEPS {
            kept.pop_front();
        }
    });
    let pack_def = std::fs::read_to_string(packs_dir.join(&pack).join("pack.def")).ok();

    // The plane's reference: the stage's own, else the first report's.
    let reference = kept
        .iter()
        .find_map(|(_, _, _, _, s)| match s.get("ref") {
            Some(Json::Arr(r)) if r.len() == 2 => Some((r[0].as_f64()?, r[1].as_f64()?)),
            _ => None,
        })
        .or_else(|| kept.iter().find_map(|(_, s, ..)| if let Step::Ingest(r) = s { Some((num(r.get("lat"))?, num(r.get("lon"))?)) } else { None }))
        .unwrap_or((0.0, 0.0));

    let mut steps = Vec::new();
    for (i, (n, step, ev, tr, snap)) in kept.iter().enumerate() {
        let mut s: Vec<(&str, Json)> = vec![("i", Json::Int(i as i64)), ("n", Json::Int(*n as i64))];
        match step {
            Step::Ingest(r) => {
                s.push(("kind", Json::Str("ingest".into())));
                s.push(("report", r.clone()));
                s.push(("t", r.get("time_ms").cloned().unwrap_or(Json::Null)));
                let src = r.get("track.source_id").and_then(Json::as_str);
                let uid = r.get("uid").map(|u| u.as_str().map(str::to_string).unwrap_or_else(|| u.to_string())).unwrap_or_default();
                s.push(("entity", Json::Str(match src {
                    Some(src) => format!("{src}/{uid}"),
                    None => uid,
                })));
                if let (Some(lat), Some(lon)) = (num(r.get("lat")), num(r.get("lon"))) {
                    let (e, no) = to_plane(reference, lat, lon);
                    s.push(("xy", arr(vec![Json::Num(e), Json::Num(no)])));
                    if let Some(ce) = num(r.get("ce")) {
                        s.push(("ce", Json::Num(ce)));
                    }
                }
            }
            Step::Tick(t) => {
                s.push(("kind", Json::Str("tick".into())));
                s.push(("t", Json::Int(*t)));
            }
            Step::Pack { .. } => continue,
        }
        let events: Vec<Json> = ev
            .iter()
            .map(|e| {
                let mut e = e.clone();
                if let (Some(lat), Some(lon), Json::Obj(m)) = (num(e.get("lat")), num(e.get("lon")), &mut e) {
                    let (x, y) = to_plane(reference, lat, lon);
                    m.insert("_xy".into(), arr(vec![Json::Num(x), Json::Num(y)]));
                }
                e
            })
            .collect();
        let (kind, cl) = clusters(snap);
        s.push(("events", Json::Arr(events)));
        s.push(("trace", Json::Arr(tr.clone())));
        s.push(("est", estimates(snap)));
        s.push(("cluster_kind", kind));
        s.push(("clusters", cl));
        s.push(("snapshot", snap.clone()));
        steps.push(obj(s));
    }

    let mut note = format!("replayed by goat-processors through its {stage} stage (pack {pack}): {total} step(s)");
    if total > kept.len() {
        note.push_str(&format!(", of which the last {} are shown", kept.len()));
    }
    if !page.focus.is_empty() {
        note.push_str(&format!("; look for {}", page.focus.join(", ")));
    }
    let data = obj(vec![
        ("name", Json::Str(page.name.clone())),
        ("pack", Json::Str(pack)),
        ("file", Json::Str(page.file.clone())),
        ("pack_def", pack_def.map(Json::Str).unwrap_or(Json::Null)),
        ("replayed", Json::Bool(true)),
        ("note", Json::Str(note)),
        ("truth_note", Json::Null),
        ("mismatch_steps", Json::Int(0)),
        ("snapshot_match", Json::Null),
        ("has_expect", Json::Bool(false)),
        ("ref", arr(vec![Json::Num(reference.0), Json::Num(reference.1)])),
        ("steps", Json::Arr(steps)),
        ("truth", Json::Null),
    ]);
    let js = finite(&data).to_string().replace("</", "<\\/");
    // The viewer names its own generator; this page has another.
    let viewer = VIEWER.replace("Generated by tools/explain/explain.py.", "Generated by goat-processors (replay --html or explain --html).");
    Ok(viewer.replace("{{TITLE}}", &escape_html(&page.name)).replace("{{DATA}}", &js))
}

/// The track's own id and its members, from a system or fused event.
pub fn names_of(track: &Json) -> Vec<String> {
    let mut out = Vec::new();
    for k in ["system", "group", "entity"] {
        if let Some(s) = track.get(k).and_then(Json::as_str) {
            out.push(s.to_string());
        }
    }
    if let Some(Json::Arr(ms)) = track.get("members") {
        out.extend(ms.iter().filter_map(|m| m.as_str().map(str::to_string)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_is_bounded_and_matches_the_spec() {
        assert_eq!(wrap180(180.0), 180.0);
        assert_eq!(wrap180(-180.0), 180.0);
        assert_eq!(wrap180(540.0), 180.0);
        assert_eq!(wrap180(190.0), -170.0);
        assert_eq!(wrap180(-725.0), -5.0);
        assert!(wrap180(1e308).is_finite());
    }

    #[test]
    fn a_vector_renders_one_page_with_every_step_and_no_external_reference() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
        let packs = root.join("packs");
        let vec_path = std::fs::read_dir(packs.join("correlate-gnn/vectors")).unwrap().filter_map(|e| e.ok()).map(|e| e.path()).find(|p| p.extension().is_some_and(|x| x == "json")).unwrap();
        let text = std::fs::read_to_string(&vec_path).unwrap();
        let rf = replay::read(&text).unwrap();
        let engine = crate::pipeline::load_stage("correlate", &packs.join("correlate-gnn")).unwrap();
        let mut p = Pipeline::new(vec![crate::pipeline::Stage { function: "correlate".into(), pack: "correlate-gnn".into(), engine }]);
        let page = Page { name: "test".into(), file: "v.json".into(), focus: vec![] };
        let html = render(&mut p, &rf, 1000, &packs, "correlate", &page).unwrap();
        assert!(!html.contains("{{DATA}}") && !html.contains("{{TITLE}}"));
        for bad in ["http://", "https://", "src=\"//"] {
            assert!(!html.contains(bad) || html.matches(bad).count() == VIEWER.matches(bad).count(), "{bad}");
        }
        let start = html.find("\"steps\":[").unwrap();
        let steps = html[start..].matches("\"kind\":").count();
        assert_eq!(steps, rf.steps.len(), "one step on the page per step of the vector");
        assert!(html.contains("\"snapshot\":{"));
        assert!(html.contains("Generated by goat-processors") && !html.contains("Generated by tools/explain"), "the footer names the runner");
        let err = render(&mut Pipeline::new(vec![]), &rf, 1000, &packs, "fuse", &page).unwrap_err();
        assert!(err.contains("no fuse stage"), "{err}");
    }
}
