//! Fuzzing of the input parsers with the seeded generator of tests/common:
//! the JSON reader (src/model/json.rs) and the `pack.def` reader of every
//! function, then every engine with malformed reports. Each target runs a
//! fixed number of cases and stops early at its time budget, so CI time is
//! bounded: `GOAT_FUZZ_CASES` (default 4000 per target) and
//! `GOAT_FUZZ_SECONDS` (default 5 per target). A failure prints the seed and
//! the input.
//!
//! What must hold: no input panics; JSON that reads back prints and reads
//! back to the same value; a pack that loads loads the same way twice. The
//! engine targets keep numbers within the range where the specs define the
//! result (DISAGREEMENTS.md, "Limits found by fuzzing").

mod common;

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::{Duration, Instant};

use common::{all_packs, json_files, read_json, repo_root, Rng};
use goat_correlator::{correlate, filter, fuse, json, quality, Function, Json};

fn cases() -> usize {
    std::env::var("GOAT_FUZZ_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(4000)
}

fn budget() -> Duration {
    Duration::from_secs(std::env::var("GOAT_FUZZ_SECONDS").ok().and_then(|v| v.parse().ok()).unwrap_or(5))
}

/// Runs `case` with a fresh seed per case until the count or the budget runs
/// out; returns how many ran.
fn fuzz(name: &str, seed: u64, mut case: impl FnMut(&mut Rng)) -> usize {
    let start = Instant::now();
    let mut ran = 0;
    for i in 0..cases() {
        if start.elapsed() > budget() {
            break;
        }
        let mut rng = Rng::new(seed.wrapping_mul(1_000_003).wrapping_add(i as u64));
        case(&mut rng);
        ran += 1;
    }
    println!("{}: {} cases in {:?}", name, ran, start.elapsed());
    assert!(ran > 0);
    ran
}

/// Inputs to start from: every vector file's text and every pack.def.
fn corpus() -> Vec<String> {
    let root = repo_root();
    let mut texts: Vec<String> = Vec::new();
    for (_, pack) in all_packs() {
        texts.push(std::fs::read_to_string(pack.join("pack.def")).unwrap());
        for v in json_files(&pack.join("vectors")).into_iter().take(2) {
            texts.push(std::fs::read_to_string(v).unwrap());
        }
    }
    for function in ["correlate", "filter", "fuse", "quality"] {
        for v in json_files(&root.join(format!("spec/{}-load-vectors", function))) {
            texts.push(std::fs::read_to_string(v).unwrap());
        }
    }
    texts
}

/// One random edit of `text`: delete, duplicate or insert a slice, flip a
/// byte to a structural character, or cut it short. The result is valid
/// UTF-8 (edits land on character boundaries).
fn mutate(rng: &mut Rng, text: &str, alphabet: &[&str]) -> String {
    let mut s = text.to_string();
    for _ in 0..1 + rng.below(4) {
        let bounds: Vec<usize> = (0..=s.len()).filter(|i| s.is_char_boundary(*i)).collect();
        let a = *rng.pick(&bounds);
        let b = bounds[(bounds.iter().position(|x| *x == a).unwrap() + rng.below(24)).min(bounds.len() - 1)];
        match rng.below(5) {
            0 => s.replace_range(a..b, ""),
            1 => {
                let piece = s[a..b].to_string();
                s.insert_str(a, &piece);
            }
            2 => s.insert_str(a, rng.pick(alphabet)),
            3 => {
                let with = rng.pick(alphabet).to_string();
                s.replace_range(a..b, &with);
            }
            _ => s.truncate(a),
        }
    }
    s
}

const JSON_ALPHABET: &[&str] = &[
    "{", "}", "[", "]", ",", ":", "\"", "\\", "\\u", "\\ud800", "\\udc00", "\\u00e9", "-", "+", ".", "e", "E", "0", "1e999", "-0.0",
    "9223372036854775808", "-9223372036854775809", "true", "false", "null", "nul", " ", "\n", "\t", "é", "😀", "\u{0}", "\u{1f}", "\"a\":",
];

fn random_json(rng: &mut Rng, depth: usize) -> String {
    match if depth > 6 { rng.below(4) } else { rng.below(7) } {
        0 => rng.pick(&["null", "true", "false", "0", "-1", "1.5e-300", "12345678901234567890", "-0"]).to_string(),
        1 => format!("{}", (rng.unit() - 0.5) * 10f64.powi(rng.below(40) as i32 - 20)),
        2 => format!("{}", rng.next_u64() as i64),
        3 => Json::Str((0..rng.below(6)).map(|_| *rng.pick(&["a", "\"", "\\", "\n", "\u{1}", "é", "😀", "/"])).collect()).to_string(),
        4 | 5 => {
            let items: Vec<String> = (0..rng.below(5)).map(|_| random_json(rng, depth + 1)).collect();
            format!("[{}]", items.join(","))
        }
        _ => {
            let items: Vec<String> =
                (0..rng.below(5)).map(|_| format!("{}:{}", Json::Str(format!("k{}", rng.below(4))), random_json(rng, depth + 1))).collect();
            format!("{{{}}}", items.join(","))
        }
    }
}

/// The reader on `text`: never a panic; a value it reads prints and reads
/// back to itself.
fn check_json(text: &str) {
    let result = catch_unwind(|| json::parse(text));
    let parsed = result.unwrap_or_else(|_| panic!("json::parse panicked on {:?}", text));
    if let Ok(v) = parsed {
        let printed = v.to_string();
        let again = json::parse(&printed).unwrap_or_else(|e| panic!("{:?} printed as {:?}, which does not read: {}", text, printed, e));
        assert!(again == v, "{:?} does not read back the same from {:?}", text, printed);
    }
}

#[test]
fn json_reader_on_mutated_corpus() {
    let corpus = corpus();
    fuzz("json mutated", 1, |rng| {
        let base = rng.pick(&corpus).clone();
        let start = base.char_indices().map(|(i, _)| i).nth(rng.below(base.chars().count().max(1))).unwrap_or(0);
        let mut end = (start + 400).min(base.len());
        while !base.is_char_boundary(end) {
            end -= 1;
        }
        // Half the time the whole text (mostly valid), else a slice.
        let text = if rng.chance(0.5) { base.as_str() } else { &base[start..end] };
        check_json(&mutate(rng, text, JSON_ALPHABET));
    });
}

#[test]
fn json_reader_on_generated_values() {
    fuzz("json generated", 2, |rng| {
        let text = random_json(rng, 0);
        check_json(&text);
        let v = json::parse(&text).unwrap_or_else(|e| panic!("generated {:?} does not read: {}", text, e));
        // Whitespace between tokens does not change the value.
        let spaced = text.replace(',', " ,\n\t").replace(':', " : ");
        if !text.contains('"') {
            assert!(json::parse(&spaced).unwrap() == v, "{:?}", spaced);
        }
    });
}

const PACK_ALPHABET: &[&str] = &[
    "\n", "\r\n", "\r", "\t", " ", "#", "=", "==", ",", ";", "-", "+", ".", "0", "-0", "1e3", "1e999", "99999999999999999999", "-1", "0.5",
    "nan", "inf", "\u{a0}", "\u{7f}", "\u{0}", "é", "not ", "min=", "max=", "rule ", "when ", "gate ", "confirm ", "hold ", "method assign\n",
    "window 2\n", "hypotheses 2\n", "margin 1\n", "bias sigma_m=1 floor_m=1 gate=1\n", "time_offset sigma_ms=1\n", "time_default a error_ms=1\n",
    "source a\n", "attribute k rule=max\n", "polygon vertices=0,0;0,1;1,1", "key name=a eq=1", "near reference=a/b radius_m=1 max_age_ms=1",
];

/// `parse_pack` of `F` on `text`: never a panic; a pack that loads loads
/// the same way twice.
fn check_pack<F: Function>(text: &str)
where
    F::Pack: std::fmt::Debug,
{
    let first = catch_unwind(AssertUnwindSafe(|| F::parse_pack(text))).unwrap_or_else(|_| panic!("{} parse_pack panicked on {:?}", F::NAME, text));
    let second = F::parse_pack(text);
    assert_eq!(format!("{:?}", first), format!("{:?}", second), "{} parse_pack is not deterministic on {:?}", F::NAME, text);
}

fn pack_corpus(function: &str) -> Vec<String> {
    let root = repo_root();
    let mut texts: Vec<String> =
        all_packs().into_iter().filter(|(f, _)| f == function).map(|(_, p)| std::fs::read_to_string(p.join("pack.def")).unwrap()).collect();
    for v in json_files(&root.join(format!("spec/{}-load-vectors", function))) {
        if let Some(t) = read_json(&v).get("pack_def").and_then(Json::as_str) {
            texts.push(t.to_string());
        }
    }
    texts
}

fn fuzz_packs<F: Function>(seed: u64)
where
    F::Pack: std::fmt::Debug,
{
    let corpus = pack_corpus(F::NAME);
    assert!(!corpus.is_empty());
    let mut loaded = 0;
    fuzz(&format!("{} pack.def", F::NAME), seed, |rng| {
        let base = rng.pick(&corpus).clone();
        let text = mutate(rng, &base, PACK_ALPHABET);
        // Also line-level edits: swap, drop or repeat whole lines.
        let mut lines: Vec<&str> = text.split('\n').collect();
        if lines.len() > 1 && rng.chance(0.5) {
            let (i, j) = (rng.below(lines.len()), rng.below(lines.len()));
            match rng.below(3) {
                0 => lines.swap(i, j),
                1 => {
                    lines.remove(i);
                }
                _ => lines.insert(i, lines[j]),
            }
        }
        let text = lines.join("\n");
        check_pack::<F>(&text);
        loaded += F::parse_pack(&text).is_ok() as usize;
    });
    println!("{}: {} mutated packs loaded", F::NAME, loaded);
}

#[test]
fn correlate_pack_def() {
    fuzz_packs::<correlate::Engine>(3);
}

#[test]
fn filter_pack_def() {
    fuzz_packs::<filter::Engine>(4);
}

#[test]
fn fuse_pack_def() {
    fuzz_packs::<fuse::Engine>(5);
}

#[test]
fn quality_pack_def() {
    fuzz_packs::<quality::Engine>(6);
}

/// A report with each key present or not, of a right or a wrong type, with
/// edge values.
fn random_report(rng: &mut Rng, t: &mut i64) -> Json {
    let number = |rng: &mut Rng| -> String {
        // Magnitudes stay below 1e6, and times far from the 64-bit limits:
        // beyond them the engines meet the limits DISAGREEMENTS.md lists
        // ("Limits found by fuzzing").
        rng.pick(&["0", "-0.0", "1e-300", "90", "-90", "180", "-180", "181", "0.5", "-3", "12", "999999.5", "-1000"]).to_string()
    };
    let value = |rng: &mut Rng| -> String {
        match rng.below(6) {
            0 => "null".into(),
            1 => "true".into(),
            2 => "\"x\"".into(),
            3 => "[1]".into(),
            4 => "{}".into(),
            _ => number(rng),
        }
    };
    *t += rng.below(4000) as i64 - 1000;
    let mut pairs = Vec::new();
    let keys = [
        ("track.source_id", format!("\"{}\"", rng.pick(&["a", "b", "c", "a/b", ""]))),
        ("uid", format!("\"{}\"", rng.pick(&["1", "2", "c", ""]))),
        ("time_ms", t.to_string()),
        ("lat", format!("{}", 50.0 + (rng.unit() - 0.5) * 0.1)),
        ("lon", format!("{}", 8.0 + (rng.unit() - 0.5) * 0.1)),
    ];
    for (k, v) in keys {
        if rng.chance(0.95) {
            // `lat` and `lon` stay within 1000 degrees: a longitude far
            // larger never ends `wrap180`; and `lat` stays off the poles,
            // where a reference makes `cos(lat0)` 0 to rounding and every
            // longitude back from the plane is that large (DISAGREEMENTS.md,
            // "Limits found by fuzzing", row 1).
            let wrong = match k {
                "lat" => rng.pick(&["null", "\"x\"", "true", "[1]", "{}", "0", "-0.0", "89.0", "-180", "180", "181", "-999.5", "5e-324"]).to_string(),
                "lon" => rng.pick(&["null", "\"x\"", "true", "[1]", "{}", "0", "-0.0", "90.0", "-180", "180", "181", "-999.5", "5e-324"]).to_string(),
                _ => value(rng),
            };
            pairs.push(format!("\"{}\":{}", k, if rng.chance(0.9) { v } else { wrong }));
        }
    }
    for k in ["ce", "course", "speed_ms", "hae", "stale_ms", "time_error_ms", "received_ms", "type", "time_state", "fuse.group", "quality.marks"] {
        if rng.chance(0.4) {
            let v = match (k, rng.below(3)) {
                ("type", 0) => format!("\"{}\"", rng.pick(&["a-f-G", "a-h", "x", "a-f-G-U-C", ""])),
                ("time_state", 0) => format!("\"{}\"", rng.pick(&["coherent", "drifting", "free-running", "late"])),
                ("fuse.group", 0) => format!("\"g{}\"", rng.below(3)),
                ("quality.marks", 0) => "[\"m\",1]".into(),
                ("stale_ms" | "received_ms", 0) => (*t + rng.below(5000) as i64).to_string(),
                _ => value(rng),
            };
            pairs.push(format!("\"{}\":{}", k, v));
        }
    }
    let text = format!("{{{}}}", pairs.join(","));
    if rng.chance(0.03) {
        return json::parse(rng.pick(&["[]", "null", "\"report\"", "3"])).unwrap();
    }
    json::parse(&text).unwrap()
}

fn fuzz_engine<F: Function>(seed: u64) {
    let packs: Vec<F::Pack> = all_packs().into_iter().filter(|(f, _)| f == F::NAME).map(|(_, p)| F::load_pack(&p).unwrap()).collect();
    fuzz(&format!("{} engine", F::NAME), seed, |rng| {
        let pack_index = rng.below(packs.len());
        let pack = F::load_pack(&all_packs().into_iter().filter(|(f, _)| f == F::NAME).nth(pack_index).unwrap().1).unwrap();
        let mut engine = F::new(pack);
        let mut t = 1_000_000;
        let mut inputs = Vec::new();
        for _ in 0..30 {
            if rng.chance(0.2) {
                let now = t + rng.below(200_000) as i64 - 50_000;
                inputs.push(format!("tick {}", now));
                let r = catch_unwind(AssertUnwindSafe(|| engine.tick(now)));
                assert!(r.is_ok(), "{} tick panicked after {:?}", F::NAME, inputs);
            } else {
                let report = random_report(rng, &mut t);
                inputs.push(report.to_string());
                let r = catch_unwind(AssertUnwindSafe(|| engine.ingest(&report)));
                assert!(r.is_ok(), "{} ingest panicked after {:?}", F::NAME, inputs);
            }
        }
        let s = catch_unwind(AssertUnwindSafe(|| engine.snapshot()));
        assert!(s.is_ok(), "{} snapshot panicked after {:?}", F::NAME, inputs);
    });
    drop(packs);
}

#[test]
fn correlate_engine_on_malformed_reports() {
    fuzz_engine::<correlate::Engine>(7);
}

#[test]
fn filter_engine_on_malformed_reports() {
    fuzz_engine::<filter::Engine>(8);
}

#[test]
fn fuse_engine_on_malformed_reports() {
    fuzz_engine::<fuse::Engine>(9);
}

#[test]
fn quality_engine_on_malformed_reports() {
    fuzz_engine::<quality::Engine>(10);
}
