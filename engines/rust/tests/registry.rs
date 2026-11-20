//! The registration point of a correlate test kind, proven with a no-op
//! kind that only this test registers: one `TestKind` value, no change to
//! the engine. The fixture pack `tests/fixtures/correlate-noop` (packs/
//! correlate-gnn with `gate noop` and `confirm noop`) loads only with it.

mod common;

use std::path::Path;
use std::sync::Arc;

use common::{compare, json_files, packs_with_prefix, read_json, repo_root};
use goat_correlator::correlate::{parse_pack_with, Engine, Outcome, Pair, PairTest, Registry, TestKind};
use goat_correlator::model::pack::read_pack_def;
use goat_correlator::{Function, Json, StepResult};

/// A test that reads nothing and always passes: trace `value` and `limit` null.
struct Noop;

impl PairTest for Noop {
    fn name(&self) -> &'static str {
        "noop"
    }
    fn evaluate(&self, _pair: &Pair) -> Outcome {
        Outcome { value: Json::Null, limit: Json::Null, pass: true, skipped: false }
    }
}

/// The whole registration of the new kind.
const NOOP: TestKind = TestKind { name: "noop", params: &[], build: |_| Ok(Arc::new(Noop)) };

fn with_noop() -> Registry {
    let mut r = Registry::builtin();
    r.register_test(NOOP);
    r
}

fn fixture() -> String {
    read_pack_def(&Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/correlate-noop")).unwrap()
}

/// Runs every step of a vector; the results and the snapshot.
fn run(engine: &mut Engine, vector: &Json) -> (Vec<StepResult>, Json) {
    let steps = vector.get("steps").and_then(Json::as_array).unwrap();
    let results = steps
        .iter()
        .map(|s| match (s.get("ingest"), s.get("tick")) {
            (Some(r), _) => engine.ingest(r),
            (None, Some(t)) => engine.tick(t.as_i64().unwrap()),
            _ => panic!("bad step"),
        })
        .collect();
    (results, engine.snapshot())
}

fn is_noop(record: &Json) -> bool {
    record.get("test").and_then(Json::as_str) == Some("noop")
}

#[test]
fn the_spec_registry_refuses_the_noop_pack() {
    let err = goat_correlator::correlate::parse_pack(&fixture()).unwrap_err();
    assert!(err.contains("unknown test"), "{}", err);
}

#[test]
fn a_registered_kind_needs_its_parameters_exactly() {
    let text = fixture().replace("gate           noop", "gate           noop extra=1");
    assert!(parse_pack_with(&text, &with_noop()).unwrap_err().contains("unknown parameter"));
}

/// The noop pack gives the base pack's events and snapshot on every base
/// vector, and its trace is the base trace with `noop` records added, each
/// passing with null `value` and `limit`.
#[test]
fn noop_kind_changes_no_decision() {
    let root = repo_root();
    let noop_pack = parse_pack_with(&fixture(), &with_noop()).unwrap();
    let base_pack = Engine::load_pack(&root.join("packs/correlate-gnn")).unwrap();
    let mut noop_records = 0;
    for path in json_files(&root.join("packs/correlate-gnn/vectors")) {
        let v = read_json(&path);
        let (base, base_snap) = run(&mut Engine::new(base_pack.clone()), &v);
        let (with, with_snap) = run(&mut Engine::new(noop_pack.clone()), &v);
        assert_eq!(base_snap, with_snap, "{}", path.display());
        for (i, (b, w)) in base.iter().zip(&with).enumerate() {
            assert_eq!(b.events, w.events, "{} step {}", path.display(), i);
            let (noops, rest): (Vec<&Json>, Vec<&Json>) = w.trace.iter().partition(|r| is_noop(r));
            assert_eq!(b.trace.iter().collect::<Vec<_>>(), rest, "{} step {}", path.display(), i);
            for r in noops {
                assert_eq!(r.get("pass"), Some(&Json::Bool(true)));
                assert_eq!(r.get("value"), Some(&Json::Null));
                noop_records += 1;
            }
        }
    }
    assert!(noop_records > 0, "the noop test never ran");
}

/// Registering the kind changes nothing for a pack that does not name it:
/// every correlate scenario vector passes with packs parsed by the noop
/// registry.
#[test]
fn registering_is_invisible_to_every_vector() {
    let root = repo_root();
    let registry = with_noop();
    for pack in packs_with_prefix(&root, "correlate-") {
        let text = read_pack_def(&pack).unwrap();
        let parsed = parse_pack_with(&text, &registry).unwrap();
        for path in json_files(&pack.join("vectors")) {
            let v = read_json(&path);
            let (results, snapshot) = run(&mut Engine::new(parsed.clone()), &v);
            for (i, (r, step)) in results.into_iter().zip(v.get("steps").and_then(Json::as_array).unwrap()).enumerate() {
                let at = format!("{} steps[{}]", path.display(), i);
                compare(&Json::Arr(r.events), step.get("expect").unwrap(), &at).unwrap();
                compare(&Json::Arr(r.trace), step.get("trace").unwrap(), &at).unwrap();
            }
            compare(&snapshot, v.get("snapshot").unwrap(), &path.display().to_string()).unwrap();
        }
    }
}
