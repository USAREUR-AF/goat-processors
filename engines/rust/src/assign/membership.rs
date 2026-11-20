//! correlate-assign.md Memberships: system tracks, the records of a history
//! and the histories; and the membership events (Events).

use std::collections::{BTreeMap, BTreeSet};

use super::{names, system_name, Choice};
use crate::model::Json;
use crate::trace::event;

/// One picture of the system tracks: members by system number (creation
/// order is number order) and the counter that names the next one.
#[derive(Debug, Clone, PartialEq)]
pub struct Membership {
    pub(crate) systems: BTreeMap<u64, BTreeSet<String>>,
    pub(crate) next_system: u64,
}

impl Default for Membership {
    fn default() -> Membership {
        Membership { systems: BTreeMap::new(), next_system: 1 }
    }
}

impl Membership {
    pub(crate) fn system_of(&self, a: &str) -> Option<u64> {
        self.systems.iter().find(|(_, ms)| ms.contains(a)).map(|(s, _)| *s)
    }

    /// A is now the only member of its system track.
    pub(crate) fn alone(&self, a: &str) -> bool {
        self.system_of(a).is_some_and(|s| self.systems[&s].len() == 1)
    }

    /// A leaves its system track if it has one (event `leave`); a track left
    /// empty ends (event `end`).
    pub(crate) fn leave(&mut self, a: &str, reason: &str, events: &mut Vec<Json>) {
        let Some(s) = self.system_of(a) else { return };
        let members = self.systems.get_mut(&s).unwrap();
        members.remove(a);
        events.push(event("leave", vec![("system", system_name(s).into()), ("entity", a.into()), ("reason", reason.into())]));
        if members.is_empty() {
            self.systems.remove(&s);
            events.push(event("end", vec![("system", system_name(s).into())]));
        }
    }

    /// Assignment of one source, step 4: apply one assignment, entities of R
    /// in key order.
    pub(crate) fn apply(&mut self, r: &[String], choices: &[Choice], events: &mut Vec<Json>) {
        for (a, c) in r.iter().zip(choices) {
            let unchanged = match c {
                Choice::Column(s) => self.system_of(a) == Some(*s),
                Choice::Alone => self.alone(a),
            };
            if unchanged {
                continue;
            }
            self.leave(a, "assign", events);
            let (ev, s) = match c {
                Choice::Column(s) => ("join", *s),
                Choice::Alone => {
                    self.next_system += 1;
                    ("start", self.next_system - 1)
                }
            };
            self.systems.entry(s).or_default().insert(a.clone());
            events.push(event(ev, vec![("system", system_name(s).into()), ("entity", a.as_str().into())]));
        }
    }

    pub(crate) fn systems_json(&self) -> Json {
        Json::Obj(self.systems.iter().map(|(s, ms)| (system_name(*s), names(ms))).collect())
    }
}

/// One pending tick of a history.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    /// Sum from 0 of the assignment totals of the tick's sources, in key order.
    pub(crate) cost: f64,
    /// `[entity, chosen]`, sources in key order, entities in key order.
    pub(crate) choices: Vec<(String, String)>,
    /// The membership events the tick produced in this history.
    pub(crate) events: Vec<Json>,
    /// The membership after the tick.
    pub(crate) membership: Membership,
}

/// Pending ticks, oldest first.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct History {
    pub(crate) records: Vec<Record>,
}

impl History {
    /// Sum from 0 of the records' `cost`, oldest first.
    pub(crate) fn total(&self) -> f64 {
        self.records.iter().fold(0.0, |sum, r| sum + r.cost)
    }

    /// The newest record's membership, or the committed one when it has none.
    pub(crate) fn latest<'a>(&'a self, committed: &'a Membership) -> &'a Membership {
        self.records.last().map_or(committed, |r| &r.membership)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(ks: &[&str]) -> Vec<String> {
        ks.iter().map(|k| k.to_string()).collect()
    }

    #[test]
    fn start_join_leave_end() {
        let mut m = Membership::default();
        let mut events = Vec::new();
        m.apply(&keys(&["a/1", "b/1"]), &[Choice::Alone, Choice::Alone], &mut events);
        assert_eq!(m.systems_json().to_string(), r#"{"s1":["a/1"],"s2":["b/1"]}"#);
        // b/1 joins s1: leaves s2 (which ends), joins s1.
        m.apply(&keys(&["b/1"]), &[Choice::Column(1)], &mut events);
        assert_eq!(m.system_of("b/1"), Some(1));
        assert!(!m.alone("b/1"));
        // Unchanged choices give no events.
        let before = events.len();
        m.apply(&keys(&["a/1"]), &[Choice::Column(1)], &mut events);
        assert_eq!(events.len(), before);
        m.leave("a/1", "stale", &mut events);
        m.leave("a/1", "stale", &mut events);
        let evs: Vec<String> = events.iter().map(|e| e.get("ev").and_then(Json::as_str).unwrap().to_string()).collect();
        assert_eq!(evs, ["start", "start", "leave", "end", "join", "leave"]);
        assert!(m.alone("b/1"));
    }

    #[test]
    fn history_total_and_latest() {
        let committed = Membership::default();
        let mut h = History::default();
        assert_eq!((h.total(), h.latest(&committed) == &committed), (0.0, true));
        let rec = |cost| Record { cost, choices: Vec::new(), events: Vec::new(), membership: Membership::default() };
        h.records.push(rec(1.5));
        h.records.push(rec(2.0));
        assert_eq!(h.total(), 3.5);
    }
}
