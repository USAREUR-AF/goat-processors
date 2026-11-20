//! Property tests, all four functions, with the seeded generator of
//! tests/common (the same inputs on every run):
//!
//! - determinism: the same input gives the same output, byte for byte, on
//!   every scenario vector and on generated report streams;
//! - order independence where the spec says order does not matter: the key
//!   order of a report (a JSON object), comment and blank lines in a
//!   `pack.def`, filter directives against the rules (filter.md Pack),
//!   `time_default` lines of different sources (correlate.md, quality.md);
//! - snapshot: the engines have no restore (a snapshot is never read back),
//!   so the property tested is the one restore would rest on: taking a
//!   snapshot changes nothing, and a copy of the engine state continues
//!   exactly as the original.

mod common;

use std::path::Path;

use common::{all_packs, all_scenario_vectors, read_json, Rng};
use goat_correlator::{correlate, filter, fuse, quality, Function, Json, StepResult};

/// One step of a run.
#[derive(Clone)]
enum Step {
    Ingest(Json),
    Tick(i64),
}

fn steps_of(vector: &Json) -> Vec<Step> {
    vector
        .get("steps")
        .and_then(Json::as_array)
        .unwrap()
        .iter()
        .map(|s| match (s.get("ingest"), s.get("tick")) {
            (Some(r), _) => Step::Ingest(r.clone()),
            (None, Some(t)) => Step::Tick(t.as_i64().unwrap()),
            _ => panic!("bad step"),
        })
        .collect()
}

/// Everything a run outputs, as one text: each step's events and trace, then
/// the snapshot. Two runs are equal when their texts are byte-identical.
fn output<F: Function>(pack: F::Pack, steps: &[Step]) -> String {
    let mut engine = F::new(pack);
    let mut out = String::new();
    for s in steps {
        let r = match s {
            Step::Ingest(report) => engine.ingest(report),
            Step::Tick(t) => engine.tick(*t),
        };
        push(&mut out, &r);
    }
    out.push_str(&engine.snapshot().to_string());
    out
}

fn push(out: &mut String, r: &StepResult) {
    out.push_str(&Json::Arr(r.events.clone()).to_string());
    out.push('\n');
    out.push_str(&Json::Arr(r.trace.clone()).to_string());
    out.push('\n');
}

/// Runs `check` with the function named `function` (its type as `F`).
macro_rules! with_function {
    ($function:expr, $check:ident ( $($arg:expr),* )) => {
        match $function {
            "correlate" => $check::<correlate::Engine>($($arg),*),
            "filter" => $check::<filter::Engine>($($arg),*),
            "fuse" => $check::<fuse::Engine>($($arg),*),
            "quality" => $check::<quality::Engine>($($arg),*),
            other => panic!("unknown function {}", other),
        }
    };
}

fn pack_text(dir: &Path) -> String {
    goat_correlator::model::pack::read_pack_def(dir).unwrap()
}

// ---- Determinism

fn same_twice<F: Function>(dir: &Path, steps: &[Step]) {
    let text = pack_text(dir);
    let a = output::<F>(F::parse_pack(&text).unwrap(), steps);
    let b = output::<F>(F::parse_pack(&text).unwrap(), steps);
    assert!(a == b, "{}: two runs differ", dir.display());
}

#[test]
fn determinism_on_every_scenario_vector() {
    for (function, pack, vector) in all_scenario_vectors() {
        let steps = steps_of(&read_json(&vector));
        with_function!(function.as_str(), same_twice(&pack, &steps));
    }
}

/// A generated stream: a few sources and tracks near one point, mostly
/// advancing times with some repeats and reversals, optional keys present
/// or not, and a tick now and then.
fn stream(rng: &mut Rng, len: usize) -> Vec<Step> {
    let sources = ["radar", "beacon", "beacon2", "passive"];
    let mut t = 1_000_000i64;
    let mut steps = Vec::with_capacity(len);
    for _ in 0..len {
        if rng.chance(0.15) {
            steps.push(Step::Tick(t + rng.below(3000) as i64));
            continue;
        }
        t += rng.below(1500) as i64 - 100;
        let source = *rng.pick(&sources);
        let uid = format!("t{}", rng.below(4));
        let mut report = vec![
            format!("\"track.source_id\":\"{}\"", source),
            format!("\"uid\":\"{}\"", uid),
            format!("\"time_ms\":{}", t),
            format!("\"lat\":{}", 50.0 + rng.unit() * 0.02),
            format!("\"lon\":{}", 8.0 + rng.unit() * 0.02),
        ];
        let optional = [
            format!("\"ce\":{}", rng.unit() * 60.0),
            format!("\"course\":{}", rng.unit() * 360.0),
            format!("\"speed_ms\":{}", rng.unit() * 40.0),
            format!("\"hae\":{}", rng.unit() * 500.0),
            format!("\"type\":\"{}\"", rng.pick(&["a-f-G-U", "a-h-A", "a-f-S"])),
            format!("\"time_error_ms\":{}", rng.below(300)),
            format!("\"time_state\":\"{}\"", rng.pick(&["coherent", "drifting", "free-running"])),
            format!("\"received_ms\":{}", t + rng.below(400) as i64),
            format!("\"fuse.group\":\"g{}\"", rng.below(3)),
            format!("\"stale_ms\":{}", t + 60_000),
        ];
        for o in optional {
            if rng.chance(0.5) {
                report.push(o);
            }
        }
        let text = format!("{{{}}}", report.join(","));
        steps.push(Step::Ingest(goat_correlator::json::parse(&text).unwrap()));
    }
    steps
}

#[test]
fn determinism_on_generated_streams_for_every_pack() {
    let mut rng = Rng::new(20261120);
    for (function, pack) in all_packs() {
        let steps = stream(&mut rng, 150);
        with_function!(function.as_str(), same_twice(&pack, &steps));
    }
}

// ---- Order independence

/// The report written with its keys in a shuffled order, read back.
fn reorder(rng: &mut Rng, report: &Json) -> Json {
    let Some(m) = report.as_object() else { return report.clone() };
    let mut pairs: Vec<String> = m.iter().map(|(k, v)| format!("{}:{}", Json::from(k.as_str()), v)).collect();
    rng.shuffle(&mut pairs);
    goat_correlator::json::parse(&format!("{{{}}}", pairs.join(","))).unwrap()
}

fn key_order_free<F: Function>(dir: &Path, steps: &[Step], rng: &mut Rng) {
    let text = pack_text(dir);
    let shuffled: Vec<Step> = steps
        .iter()
        .map(|s| match s {
            Step::Ingest(r) => Step::Ingest(reorder(rng, r)),
            t => t.clone(),
        })
        .collect();
    let a = output::<F>(F::parse_pack(&text).unwrap(), steps);
    let b = output::<F>(F::parse_pack(&text).unwrap(), &shuffled);
    assert!(a == b, "{}: the key order of a report changed the output", dir.display());
}

#[test]
fn report_key_order_does_not_matter() {
    let mut rng = Rng::new(7);
    for (function, pack, vector) in all_scenario_vectors() {
        let steps = steps_of(&read_json(&vector));
        with_function!(function.as_str(), key_order_free(&pack, &steps, &mut rng));
    }
}

/// `text` with comment lines and blank lines inserted between its lines,
/// and a comment after some lines.
fn with_comments(rng: &mut Rng, text: &str) -> String {
    let mut out = String::new();
    for line in text.lines() {
        if rng.chance(0.3) {
            out.push_str(rng.pick(&["\n", "# a comment line\n", "   \t\n", "#\n"]));
        }
        out.push_str(line);
        if rng.chance(0.3) && !line.trim().is_empty() {
            out.push_str("   # trailing comment");
        }
        out.push('\n');
    }
    out
}

fn same_on_vectors<F: Function>(dir: &Path, other_text: &str) {
    let text = pack_text(dir);
    for v in common::json_files(&dir.join("vectors")) {
        let steps = steps_of(&read_json(&v));
        let a = output::<F>(F::parse_pack(&text).unwrap(), &steps);
        let b = output::<F>(F::parse_pack(other_text).unwrap_or_else(|e| panic!("{}: {}", dir.display(), e)), &steps);
        assert!(a == b, "{}: {} differs", dir.display(), v.display());
    }
}

#[test]
fn comments_and_blank_lines_do_not_matter() {
    let mut rng = Rng::new(11);
    for (function, pack) in all_packs() {
        let text = with_comments(&mut rng, &pack_text(&pack));
        with_function!(function.as_str(), same_on_vectors(&pack, &text));
    }
}

/// filter.md Pack: "Other directives may appear in any order relative to the
/// rules." The pack's other directives are moved between whole rules.
#[test]
fn filter_directives_in_any_order_relative_to_the_rules() {
    let mut rng = Rng::new(13);
    for (function, pack) in all_packs().into_iter().filter(|(f, _)| f == "filter") {
        let text = pack_text(&pack);
        let (mut blocks, mut others): (Vec<Vec<String>>, Vec<String>) = (Vec::new(), Vec::new());
        for line in text.lines() {
            let word = line.split('#').next().unwrap().split_whitespace().next();
            match word {
                Some("rule") => blocks.push(vec![line.to_string()]),
                Some("when") => blocks.last_mut().unwrap().push(line.to_string()),
                Some(_) => others.push(line.to_string()),
                None => {}
            }
        }
        for _ in 0..5 {
            let mut lines: Vec<Vec<String>> = blocks.clone();
            for o in &others {
                let at = rng.below(lines.len() + 1);
                lines.insert(at, vec![o.clone()]);
            }
            let moved = lines.concat().join("\n");
            with_function!(function.as_str(), same_on_vectors(&pack, &moved));
        }
    }
}

/// Two pack texts give the same output on the pack's vectors.
fn texts_agree<F: Function>(dir: &Path, a_text: &str, b_text: &str) {
    for v in common::json_files(&dir.join("vectors")) {
        let steps = steps_of(&read_json(&v));
        let a = output::<F>(F::parse_pack(a_text).unwrap(), &steps);
        let b = output::<F>(F::parse_pack(b_text).unwrap(), &steps);
        assert!(a == b, "{}: {} differs", dir.display(), v.display());
    }
}

/// correlate.md and quality.md: time quality is found per source; the
/// `time_default` lines of different sources may come in any order. Each
/// pack with time quality gets lines for more sources, then they are
/// shuffled.
#[test]
fn time_default_lines_in_any_order() {
    let mut rng = Rng::new(17);
    let mut tried = 0;
    for (function, pack) in all_packs().into_iter().filter(|(f, _)| f == "correlate" || f == "quality") {
        let text = pack_text(&pack);
        if !text.contains("time_default") {
            continue;
        }
        tried += 1;
        let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
        for (source, line) in [
            ("radar", "time_default radar error_ms=40 state=coherent"),
            ("beacon", "time_default beacon error_ms=250"),
            ("passive", "time_default passive state=drifting"),
            ("sensor-x", "time_default sensor-x error_ms=5"),
        ] {
            let mine = format!("time_default {} ", source);
            if !lines.iter().any(|l| l.trim_start().starts_with(&mine)) {
                lines.push(line.to_string());
            }
        }
        let base = lines.join("\n");
        let slots: Vec<usize> = (0..lines.len()).filter(|i| lines[*i].trim_start().starts_with("time_default")).collect();
        assert!(slots.len() >= 2);
        for _ in 0..4 {
            let mut order = slots.clone();
            rng.shuffle(&mut order);
            let mut moved = lines.clone();
            for (slot, from) in slots.iter().zip(&order) {
                moved[*slot] = lines[*from].clone();
            }
            with_function!(function.as_str(), texts_agree(&pack, &base, &moved.join("\n")));
        }
    }
    assert!(tried > 0, "no pack with time quality");
}

// ---- Snapshot

/// Taking a snapshot after every step changes nothing, and a copy of the
/// engine taken half way continues exactly as the original.
fn snapshot_is_an_observation<F: Function + Clone>(dir: &Path, steps: &[Step]) {
    let text = pack_text(dir);
    let plain = output::<F>(F::parse_pack(&text).unwrap(), steps);

    let mut engine = F::new(F::parse_pack(&text).unwrap());
    let mut observed = String::new();
    let mut copy: Option<(F, String)> = None;
    for (i, s) in steps.iter().enumerate() {
        if i == steps.len() / 2 {
            copy = Some((engine.clone(), observed.clone()));
        }
        let r = match s {
            Step::Ingest(report) => engine.ingest(report),
            Step::Tick(t) => engine.tick(*t),
        };
        let _ = engine.snapshot();
        push(&mut observed, &r);
    }
    observed.push_str(&engine.snapshot().to_string());
    assert!(plain == observed, "{}: a snapshot changed the output", dir.display());

    let (mut copy, mut continued) = copy.unwrap();
    for s in &steps[steps.len() / 2..] {
        let r = match s {
            Step::Ingest(report) => copy.ingest(report),
            Step::Tick(t) => copy.tick(*t),
        };
        push(&mut continued, &r);
    }
    continued.push_str(&copy.snapshot().to_string());
    assert!(plain == continued, "{}: the copy continued differently", dir.display());
}

#[test]
fn snapshot_changes_nothing_and_a_copy_continues_the_same() {
    let mut rng = Rng::new(19);
    for (function, pack, vector) in all_scenario_vectors() {
        let steps = steps_of(&read_json(&vector));
        with_function!(function.as_str(), snapshot_is_an_observation(&pack, &steps));
    }
    for (function, pack) in all_packs() {
        let steps = stream(&mut rng, 100);
        with_function!(function.as_str(), snapshot_is_an_observation(&pack, &steps));
    }
}
