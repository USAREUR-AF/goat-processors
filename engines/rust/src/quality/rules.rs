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
            let step = step(rule, *state, value);
            *state = step.state;
            if let Some((ev, reason)) = step.event {
                out.events.push(action_event(ev, rule, subject, v.clone(), reason));
            }
            let (limit, pass) = (step.limit, step.pass);
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

}

/// What one evaluation of a rule for a subject gives.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Step {
    /// The rule state after the evaluation.
    pub(super) state: RuleState,
    /// `action-start`, or `action-end` with reason `clear`.
    pub(super) event: Option<(&'static str, Option<&'static str>)>,
    /// The trace `limit` (`limit` while inactive, `clear` while active) and `pass`.
    pub(super) limit: f64,
    pub(super) pass: bool,
}

/// Spec Rules, Evaluation, for one rule and subject with the measure's
/// `value` (`None` when null). Inactive: `pass` when `value op limit`; the
/// count of consecutive passes reaching `for` starts the action. Active: the
/// action ends when the value clears. Pure.
pub(super) fn step(rule: &Rule, mut state: RuleState, value: Option<f64>) -> Step {
    if !state.active {
        let met = value.is_some_and(|x| rule.op.holds(x, rule.limit));
        state.count = if met { state.count + 1 } else { 0 };
        let mut event = None;
        if state.count >= rule.for_n {
            state.active = true;
            state.count = 0;
            event = Some(("action-start", None));
        }
        Step { state, event, limit: rule.limit, pass: met }
    } else {
        let cleared = value.is_some_and(|x| rule.op.clears(x, rule.clear));
        let mut event = None;
        if cleared {
            state.active = false;
            event = Some(("action-end", Some("clear")));
        }
        Step { state, event, limit: rule.clear, pass: cleared }
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(op: Op, limit: f64, for_n: u64, clear: f64) -> Rule {
        Rule { name: "r".into(), scope: Scope::Entity, measure: "age".into(), op, limit, for_n, clear, action: Action::Alert }
    }

    #[test]
    fn starts_after_for_consecutive_passes_and_clears() {
        let r = rule(Op::Gt, 10.0, 2, 5.0);
        let s0 = RuleState::default();
        let s1 = step(&r, s0, Some(11.0));
        assert_eq!((s1.state.count, s1.state.active, s1.event, s1.pass, s1.limit), (1, false, None, true, 10.0));
        // A null value or a miss resets the count.
        assert_eq!(step(&r, s1.state, None).state.count, 0);
        let s2 = step(&r, s1.state, Some(12.0));
        assert_eq!((s2.state.active, s2.state.count, s2.event), (true, 0, Some(("action-start", None))));
        let held = step(&r, s2.state, Some(6.0));
        assert_eq!((held.state.active, held.pass, held.limit), (true, false, 5.0));
        let cleared = step(&r, held.state, Some(4.0));
        assert_eq!((cleared.state.active, cleared.event), (false, Some(("action-end", Some("clear")))));
    }

    #[test]
    fn ops_hold_and_clear_on_their_side() {
        assert!(Op::Lt.holds(1.0, 2.0) && Op::Le.holds(2.0, 2.0) && Op::Ge.holds(2.0, 2.0) && !Op::Gt.holds(2.0, 2.0));
        assert!(Op::Lt.clears(3.0, 2.0) && !Op::Le.clears(2.0, 2.0) && Op::Ge.clears(1.0, 2.0));
        let e = action_event("action-end", &rule(Op::Lt, 1.0, 1, 1.0), "s", Json::Null, Some("forget"));
        assert_eq!(e.to_string(), r#"{"action":"alert","ev":"action-end","reason":"forget","rule":"r","scope":"entity","subject":"s","value":null}"#);
    }
}
