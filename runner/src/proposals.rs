//! Settings proposals (docs/design/agentic-ai.md, section 4.3).
//!
//! A proposal asks for one function to run another installed pack. Anyone
//! who may read may propose; nothing changes until the proposal is applied.
//!
//! | Path | Who decides | When it applies |
//! |---|---|---|
//! | a person approves | an identity with the role operate (CLI `proposal approve`) | at once |
//! | the site policy approves | `agents.auto_approve` names the proposer, the function and the allowed packs | when the policy's gate command exits 0 |
//!
//! An applied proposal is a pack selection, written to the record file like
//! `pack use`. `revert` restores the pack it replaced. Every proposal and
//! every decision is kept in `agents.proposals_file` and in the audit log.

use std::collections::BTreeMap;
use std::path::Path;

use goat_correlator::json::{self, Json};

#[derive(Debug, Clone, PartialEq)]
pub enum State {
    /// Waiting for a person.
    Pending,
    /// Inside the site policy; its gate is running.
    Gating,
    Applied,
    Rejected,
    /// The policy's gate failed; waiting for a person.
    GateFailed,
    Reverted,
}

impl State {
    pub fn name(&self) -> &'static str {
        match self {
            State::Pending => "pending",
            State::Gating => "gating",
            State::Applied => "applied",
            State::Rejected => "rejected",
            State::GateFailed => "gate-failed",
            State::Reverted => "reverted",
        }
    }
    fn parse(s: &str) -> State {
        match s {
            "gating" | "pending" => State::Pending,
            "applied" => State::Applied,
            "rejected" => State::Rejected,
            "gate-failed" => State::GateFailed,
            "reverted" => State::Reverted,
            _ => State::Pending,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Proposal {
    pub id: String,
    pub by: String,
    pub via: String,
    pub at_ms: i64,
    pub function: String,
    pub pack: String,
    pub previous_pack: String,
    pub reason: String,
    pub state: State,
    /// Who decided, and how: an identity, or `policy`.
    pub decided_by: Option<String>,
    pub gate: Option<Json>,
}

impl Proposal {
    pub fn to_json(&self) -> Json {
        let mut m = BTreeMap::new();
        let s = |v: &str| Json::Str(v.into());
        m.insert("id".into(), s(&self.id));
        m.insert("by".into(), s(&self.by));
        m.insert("via".into(), s(&self.via));
        m.insert("at_ms".into(), Json::Int(self.at_ms));
        m.insert("function".into(), s(&self.function));
        m.insert("pack".into(), s(&self.pack));
        m.insert("previous_pack".into(), s(&self.previous_pack));
        m.insert("reason".into(), s(&self.reason));
        m.insert("state".into(), s(self.state.name()));
        m.insert("decided_by".into(), self.decided_by.clone().map(Json::Str).unwrap_or(Json::Null));
        m.insert("gate".into(), self.gate.clone().unwrap_or(Json::Null));
        Json::Obj(m)
    }

    fn from_json(v: &Json) -> Option<Proposal> {
        let g = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::to_string);
        Some(Proposal {
            id: g("id")?,
            by: g("by")?,
            via: g("via").unwrap_or_default(),
            at_ms: v.get("at_ms").and_then(|x| x.as_i64()).unwrap_or(0),
            function: g("function")?,
            pack: g("pack")?,
            previous_pack: g("previous_pack").unwrap_or_default(),
            reason: g("reason").unwrap_or_default(),
            state: State::parse(&g("state").unwrap_or_default()),
            decided_by: g("decided_by"),
            gate: v.get("gate").filter(|x| **x != Json::Null).cloned(),
        })
    }
}

#[derive(Default)]
pub struct Book {
    pub list: Vec<Proposal>,
    next: u64,
}

impl Book {
    /// Reads the proposals file. A proposal whose gate was running when the
    /// service stopped is pending again: its gate did not finish.
    pub fn load(path: &Path) -> Book {
        let list: Vec<Proposal> = std::fs::read_to_string(path)
            .ok()
            .and_then(|t| json::parse(&t).ok())
            .and_then(|v| v.as_array().cloned())
            .map(|a| a.iter().filter_map(Proposal::from_json).collect())
            .unwrap_or_default();
        let next = list.iter().filter_map(|p| p.id.strip_prefix('p').and_then(|n| n.parse::<u64>().ok())).max().unwrap_or(0);
        Book { list, next }
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, format!("{}\n", Json::Arr(self.list.iter().map(Proposal::to_json).collect()))).map_err(|e| format!("{}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| e.to_string())
    }

    pub fn new_id(&mut self) -> String {
        self.next += 1;
        format!("p{}", self.next)
    }

    pub fn get_mut(&mut self, id: &str) -> Option<&mut Proposal> {
        self.list.iter_mut().find(|p| p.id == id)
    }

    pub fn to_json(&self) -> Json {
        Json::Arr(self.list.iter().map(Proposal::to_json).collect())
    }
}

/// Runs a policy gate, off the service loop. Returns (passed, a summary).
pub fn run_gate(cmd: &[String], timeout_s: u64, function: &str, pack: &str) -> (bool, Json) {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let mut m = BTreeMap::new();
    m.insert("command".into(), Json::Arr(cmd.iter().map(|c| Json::Str(c.clone())).collect()));
    let started = Instant::now();
    let child = Command::new(&cmd[0])
        .args(&cmd[1..])
        .env("GOAT_PROPOSAL_FUNCTION", function)
        .env("GOAT_PROPOSAL_PACK", pack)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            m.insert("error".into(), Json::Str(format!("cannot run {}: {e}", cmd[0])));
            return (false, Json::Obj(m));
        }
    };
    let deadline = started + Duration::from_secs(timeout_s);
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break Some(st),
            Ok(None) if Instant::now() > deadline => {
                let _ = child.kill();
                break None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(_) => break None,
        }
    };
    let out = child.wait_with_output().ok();
    let tail = out
        .map(|o| {
            let t = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
            let lines: Vec<&str> = t.lines().collect();
            lines[lines.len().saturating_sub(5)..].join("\n")
        })
        .unwrap_or_default();
    m.insert("seconds".into(), Json::Num(started.elapsed().as_secs_f64()));
    m.insert("output_tail".into(), Json::Str(tail));
    let passed = status.is_some_and(|s| s.success());
    m.insert("exit".into(), status.and_then(|s| s.code()).map(|c| Json::Int(c as i64)).unwrap_or(Json::Null));
    if status.is_none() {
        m.insert("error".into(), Json::Str(format!("timed out after {timeout_s} s")));
    }
    m.insert("passed".into(), Json::Bool(passed));
    (passed, Json::Obj(m))
}
