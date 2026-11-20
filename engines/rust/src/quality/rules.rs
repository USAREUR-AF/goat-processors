//! quality.md Rules: evaluation per subject, the actions in force, the end
//! of a forgotten subject's actions, and the `action-start`/`action-end`
//! events (Events).

use super::*;

impl Engine {
    /// Spec Rules, Actions: is `rule` active for its subject, the report's
    /// entity (scope `entity`) or the report's own `track.source_id` (scope
    /// `source`; Reports)?
    pub(super) fn in_force(&self, rule: &Rule, key: &str, source: &str) -> bool {
        let subject = match rule.scope {
            Scope::Entity => key,
            Scope::Source => source,
        };
        self.rules[&rule.name].get(subject).is_some_and(|s| s.active)
    }


    /// Spec Tick, steps 2 and 3: each active rule of the scope for the
    /// subject ends (reason `forget`, value null), in pack order; every rule
    /// state for the subject is removed.
    pub(super) fn forget_subject(&mut self, scope: Scope, subject: &str, out: &mut StepResult) {
        for rule in self.pack.rules.iter().filter(|r| r.scope == scope) {
            let states = self.rules.get_mut(&rule.name).unwrap();
            if let Some(state) = states.remove(subject) {
                if state.active {
                    out.events.push(action_event("action-end", rule, subject, Json::Null, Some("forget")));
                }
            }
        }
    }

    /// Spec Rules, Evaluation: each rule of the scope, in pack order, for one
    /// subject; events `action-start`/`action-end` and one trace record each.
    pub(super) fn evaluate_rules(&mut self, scope: Scope, subject: &str, measures: &Measures, out: &mut StepResult) {
        for rule in self.pack.rules.iter().filter(|r| r.scope == scope) {
            let v = &measures[rule.measure.as_str()];
            let value = v.as_f64();
            let state = self.rules.get_mut(&rule.name).unwrap().entry(subject.to_string()).or_default();
            let (limit, pass) = if !state.active {
                let met = value.is_some_and(|x| rule.op.holds(x, rule.limit));
                state.count = if met { state.count + 1 } else { 0 };
                if state.count >= rule.for_n {
                    state.active = true;
                    state.count = 0;
                    out.events.push(action_event("action-start", rule, subject, v.clone(), None));
                }
                (rule.limit, met)
            } else {
                let cleared = value.is_some_and(|x| rule.op.clears(x, rule.clear));
                if cleared {
                    state.active = false;
                    out.events.push(action_event("action-end", rule, subject, v.clone(), Some("clear")));
                }
                (rule.clear, cleared)
            };
            out.trace.push(obj(vec![
                ("stage", "rule".into()),
                ("rule", rule.name.as_str().into()),
                ("subject", subject.into()),
                ("measure", rule.measure.as_str().into()),
                ("value", v.clone()),
                ("limit", Json::Num(limit)),
                ("pass", pass.into()),
                ("count", Json::Int(state.count as i64)),
                ("active", state.active.into()),
            ]));
        }
    }

    // ---- Snapshot ----------------------------------------------------------
}

/// Spec Events: `action-start`, or `action-end` with its reason.
pub(super) fn action_event(ev: &str, rule: &Rule, subject: &str, value: Json, reason: Option<&str>) -> Json {
    let mut fields = vec![
        ("ev", ev.into()),
        ("rule", rule.name.as_str().into()),
        ("scope", rule.scope.name().into()),
        ("subject", subject.into()),
        ("action", rule.action.name().into()),
        ("value", value),
    ];
    if let Some(reason) = reason {
        fields.push(("reason", reason.into()));
    }
    obj(fields)
}
