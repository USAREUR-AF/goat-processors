//! The declared pipeline: the four functions of the Rust engine, called
//! through their public API only (`load_pack`, `Engine::new`, `ingest`,
//! `tick`, `snapshot`).
//!
//! A report goes through the stages in order. A stage passes it on unless:
//! filter returns `drop` or `reject`; correlate or fuse returns `reject`;
//! quality returns `reject` or a `pass` with `withheld: true`.
//!
//! When correlate runs before fuse, the runner sets each report's
//! `fuse.group` to the group (method `confirm`) or system track (method
//! `assign`) that holds its entity after correlate's last call, and removes
//! the key when the entity is in none. Correlate's events are the only source
//! of that membership.
//!
//! A tick calls `tick(now_ms)` on every stage, in order.

use std::collections::BTreeMap;
use std::path::Path;

use goat_correlator::json::Json;
use goat_correlator::{filter_fn, fuse, quality, StepResult};

pub enum Engine {
    Filter(filter_fn::Engine),
    Correlate(goat_correlator::Engine),
    Fuse(fuse::Engine),
    Quality(quality::Engine),
}

impl Engine {
    fn ingest(&mut self, r: &Json) -> StepResult {
        match self {
            Engine::Filter(e) => e.ingest(r),
            Engine::Correlate(e) => e.ingest(r),
            Engine::Fuse(e) => e.ingest(r),
            Engine::Quality(e) => e.ingest(r),
        }
    }
    fn tick(&mut self, now_ms: i64) -> StepResult {
        match self {
            Engine::Filter(e) => e.tick(now_ms),
            Engine::Correlate(e) => e.tick(now_ms),
            Engine::Fuse(e) => e.tick(now_ms),
            Engine::Quality(e) => e.tick(now_ms),
        }
    }
    pub fn snapshot(&self) -> Json {
        match self {
            Engine::Filter(e) => e.snapshot(),
            Engine::Correlate(e) => e.snapshot(),
            Engine::Fuse(e) => e.snapshot(),
            Engine::Quality(e) => e.snapshot(),
        }
    }
}

/// Loads one function's pack and makes its engine.
pub fn load_stage(function: &str, dir: &Path) -> Result<Engine, String> {
    Ok(match function {
        "filter" => Engine::Filter(filter_fn::Engine::new(filter_fn::load_pack(dir)?)),
        "correlate" => Engine::Correlate(goat_correlator::Engine::new(goat_correlator::load_pack(dir)?)),
        "fuse" => Engine::Fuse(fuse::Engine::new(fuse::load_pack(dir)?)),
        "quality" => Engine::Quality(quality::Engine::new(quality::load_pack(dir)?)),
        other => return Err(format!("unknown function {other:?}")),
    })
}

pub struct Stage {
    pub function: String,
    pub pack: String,
    pub engine: Engine,
}

/// What one stage returned for one call.
#[derive(Debug, Clone)]
pub struct StageOutput {
    pub function: String,
    pub events: Vec<Json>,
    pub trace: Vec<Json>,
}

/// What one call on the pipeline returned: one entry per stage called.
#[derive(Debug, Clone, Default)]
pub struct Output {
    pub stages: Vec<StageOutput>,
}

#[derive(Default)]
pub struct Counters {
    pub reports_in: u64,
    pub reports_out: u64,
    pub ticks: u64,
    /// Reports read per source (`track.source_id`), in key order.
    pub per_source: BTreeMap<String, u64>,
    /// Reports stopped per stage: function -> count.
    pub stopped: BTreeMap<String, u64>,
}

pub struct Pipeline {
    pub stages: Vec<Stage>,
    /// entity -> group or system track, from correlate's events.
    membership: BTreeMap<String, String>,
    /// group or system track -> members (confirm needs this for `dissolve`).
    groups: BTreeMap<String, Vec<String>>,
    pub counters: Counters,
    pub last_now_ms: Option<i64>,
    /// entity -> the provenance of its latest agent-derived report
    /// (`provenance.kind` = `agent`), carried onto the system tracks it joins.
    provenance: BTreeMap<String, Json>,
}

impl Pipeline {
    pub fn new(stages: Vec<Stage>) -> Pipeline {
        Pipeline { stages, membership: BTreeMap::new(), groups: BTreeMap::new(), counters: Counters::default(), last_now_ms: None, provenance: BTreeMap::new() }
    }

    /// Builds the pipeline from a checked config.
    pub fn from_config(c: &crate::config::Config) -> Result<Pipeline, String> {
        let mut stages = Vec::new();
        for s in &c.pipeline {
            let engine = load_stage(&s.function, &c.pack_dir(s)).map_err(|e| format!("{} pack {}: {e}", s.function, s.pack))?;
            stages.push(Stage { function: s.function.clone(), pack: s.pack.clone(), engine });
        }
        Ok(Pipeline::new(stages))
    }

    pub fn ingest(&mut self, report: &Json) -> Output {
        self.counters.reports_in += 1;
        if let Some(src) = report.get("track.source_id").and_then(|v| v.as_str()) {
            *self.counters.per_source.entry(src.to_string()).or_default() += 1;
        }
        if let Some((entity, prov)) = agent_provenance(report) {
            self.provenance.insert(entity, prov);
        }
        let mut out = Output::default();
        let mut report = report.clone();
        let mut correlate_seen = false;
        let mut passed = true;
        for stage in self.stages.iter_mut() {
            if stage.function == "fuse" && correlate_seen {
                set_group(&mut report, &self.membership);
            }
            let step = stage.engine.ingest(&report);
            let stop = stops(&stage.function, &step.events);
            if stage.function == "correlate" {
                correlate_seen = true;
                track_membership(&mut self.membership, &mut self.groups, &step.events);
            }
            out.stages.push(StageOutput { function: stage.function.clone(), events: step.events, trace: step.trace });
            if stop {
                *self.counters.stopped.entry(stage.function.clone()).or_default() += 1;
                passed = false;
                break;
            }
        }
        if passed {
            self.counters.reports_out += 1;
        }
        out
    }

    pub fn tick(&mut self, now_ms: i64) -> Output {
        self.counters.ticks += 1;
        self.last_now_ms = Some(now_ms);
        let mut out = Output::default();
        for stage in self.stages.iter_mut() {
            let step = stage.engine.tick(now_ms);
            if stage.function == "correlate" {
                track_membership(&mut self.membership, &mut self.groups, &step.events);
            }
            out.stages.push(StageOutput { function: stage.function.clone(), events: step.events, trace: step.trace });
        }
        if !self.provenance.is_empty() {
            self.mark_agent_tracks(&mut out);
        }
        out
    }

    /// Adds `agent_provenance` (member -> provenance) to every system track
    /// of the track stage that has an agent-derived member.
    fn mark_agent_tracks(&self, out: &mut Output) {
        let Some(i) = out.stages.iter().rposition(|s| s.function == "fuse" || s.function == "correlate") else { return };
        for e in out.stages[i].events.iter_mut() {
            if !matches!(e.get("ev").and_then(|v| v.as_str()), Some("system") | Some("fused")) {
                continue;
            }
            let members: Vec<String> = match e.get("members") {
                Some(Json::Arr(m)) => m.iter().filter_map(|x| x.as_str().map(str::to_string)).collect(),
                _ => continue,
            };
            let marks: goat_correlator::json::Map = members.iter().filter_map(|m| self.provenance.get(m).map(|p| (m.clone().into(), p.clone()))).collect();
            if let (Json::Obj(map), false) = (e, marks.is_empty()) {
                map.insert("agent_provenance".into(), Json::Obj(marks));
            }
        }
    }

    /// Replaces one function's engine with a fresh one on another pack. The
    /// function's state starts empty; the other stages keep theirs. When the
    /// function is correlate, the membership behind `fuse.group` starts empty too.
    pub fn use_pack(&mut self, function: &str, pack: &str, packs_dir: &Path) -> Result<(), String> {
        let i = self.stages.iter().position(|s| s.function == function).ok_or_else(|| format!("the pipeline has no {function} stage"))?;
        if !pack.starts_with(&format!("{function}-")) {
            return Err(format!("{pack:?} is not a {function} pack"));
        }
        if pack.contains('/') || pack.contains("..") {
            return Err(format!("{pack:?} is not a pack name"));
        }
        let engine = load_stage(function, &packs_dir.join(pack))?;
        self.stages[i] = Stage { function: function.to_string(), pack: pack.to_string(), engine };
        if function == "correlate" {
            self.membership.clear();
            self.groups.clear();
        }
        Ok(())
    }

    /// Every stage's snapshot, by function.
    pub fn snapshot(&self) -> Json {
        let mut m = BTreeMap::new();
        for s in &self.stages {
            m.insert(s.function.clone().into(), s.engine.snapshot());
        }
        Json::Obj(m)
    }
}

/// The entity and provenance of an agent-derived report.
pub fn agent_provenance(r: &Json) -> Option<(String, Json)> {
    if r.get("provenance.kind").and_then(|v| v.as_str()) != Some("agent") {
        return None;
    }
    let entity = format!("{}/{}", r.get("track.source_id")?.as_str()?, r.get("uid")?.as_str()?);
    let mut m = BTreeMap::new();
    for k in ["agent", "model", "inputs"] {
        if let Some(v) = r.get(&format!("provenance.{k}")) {
            m.insert(k.to_string().into(), v.clone());
        }
    }
    // true only for a report an agent published through the API, where the
    // runner checked the identity; false for provenance as a publisher wrote it.
    m.insert("checked".into(), Json::Bool(matches!(r.get("provenance.checked"), Some(Json::Bool(true)))));
    Some((entity, Json::Obj(m)))
}

fn ev_name(e: &Json) -> &str {
    e.get("ev").and_then(|v| v.as_str()).unwrap_or("")
}

/// Whether a stage's events stop the report there.
fn stops(function: &str, events: &[Json]) -> bool {
    events.iter().any(|e| match ev_name(e) {
        "reject" => true,
        "drop" => function == "filter",
        "pass" => function == "quality" && matches!(e.get("withheld"), Some(Json::Bool(true))),
        _ => false,
    })
}

fn set_group(report: &mut Json, membership: &BTreeMap<String, String>) {
    let entity = match (report.get("track.source_id").and_then(|v| v.as_str()), report.get("uid").and_then(|v| v.as_str())) {
        (Some(s), Some(u)) => format!("{s}/{u}"),
        _ => return,
    };
    if let Json::Obj(m) = report {
        match membership.get(&entity) {
            Some(g) => {
                m.insert("fuse.group".into(), Json::Str(g.clone()));
            }
            None => {
                m.remove("fuse.group");
            }
        }
    }
}

fn s(e: &Json, k: &str) -> Option<String> {
    e.get(k).and_then(|v| v.as_str()).map(str::to_string)
}

/// Follows correlate's membership events (both methods).
fn track_membership(m: &mut BTreeMap<String, String>, groups: &mut BTreeMap<String, Vec<String>>, events: &[Json]) {
    for e in events {
        let group = s(e, "group").or_else(|| s(e, "system"));
        match ev_name(e) {
            "correlate" => {
                if let (Some(g), Some(Json::Arr(members))) = (group, e.get("members")) {
                    let members: Vec<String> = members.iter().filter_map(|v| v.as_str().map(str::to_string)).collect();
                    for x in &members {
                        m.insert(x.clone(), g.clone());
                    }
                    groups.insert(g, members);
                }
            }
            "join" | "start" => {
                if let (Some(g), Some(x)) = (group, s(e, "entity")) {
                    m.insert(x.clone(), g.clone());
                    groups.entry(g).or_default().push(x);
                }
            }
            "leave" => {
                if let (Some(g), Some(x)) = (group, s(e, "entity")) {
                    if m.get(&x) == Some(&g) {
                        m.remove(&x);
                    }
                    if let Some(list) = groups.get_mut(&g) {
                        list.retain(|y| *y != x);
                    }
                }
            }
            "dissolve" | "end" => {
                if let Some(g) = group {
                    for x in groups.remove(&g).unwrap_or_default() {
                        if m.get(&x) == Some(&g) {
                            m.remove(&x);
                        }
                    }
                }
            }
            "drop" => {
                if let Some(x) = s(e, "entity") {
                    m.remove(&x);
                }
            }
            _ => {}
        }
    }
}
