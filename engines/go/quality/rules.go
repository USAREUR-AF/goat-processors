package quality

import (
	"goat-correlator/engines/go/trace"
)

// forgetSubject ends every active rule of the scope for the subject, in pack
// order, and removes every rule state for it (spec: Tick, steps 2 and 3).
func (g *Engine) forgetSubject(scope, subject string) []Obj {
	var events []Obj
	for i, rule := range g.pack.Rules {
		if rule.Scope != scope {
			continue
		}
		if st := g.states[i][subject]; st != nil && st.active {
			events = append(events, Obj{"ev": "action-end", "rule": rule.Name, "scope": scope,
				"subject": subject, "action": rule.Action, "reason": "forget", "value": nil})
		}
		delete(g.states[i], subject)
	}
	return events
}

// holds reports whether `v op x` holds, compared as binary64 (spec: Rules).
func holds(v float64, op string, x float64) bool {
	switch op {
	case "<":
		return v < x
	case "<=":
		return v <= x
	case ">":
		return v > x
	}
	return v >= x
}

// evaluate runs each rule of the scope for the subject, in pack order
// (spec: Rules, Evaluation; Trace).
func (g *Engine) evaluate(scope, subject string, m Obj, events, tr []Obj) ([]Obj, []Obj) {
	for i, rule := range g.pack.Rules {
		if rule.Scope != scope {
			continue
		}
		st := g.states[i][subject]
		if st == nil {
			st = &ruleState{}
			g.states[i][subject] = st
		}
		value := m[rule.Measure]
		next, s := rule.step(*st, value)
		*st = next
		switch {
		case s.started:
			events = append(events, Obj{"ev": "action-start", "rule": rule.Name, "scope": scope,
				"subject": subject, "action": rule.Action, "value": value})
		case s.ended:
			events = append(events, Obj{"ev": "action-end", "rule": rule.Name, "scope": scope,
				"subject": subject, "action": rule.Action, "reason": "clear", "value": value})
		}
		tr = append(tr, trace.QualityRule(rule.Name, subject, rule.Measure, value, s.limit, s.pass, st.count, st.active))
	}
	return events, tr
}

// stepResult is what one evaluation of a rule found.
type stepResult struct {
	limit          float64 // the limit or clear the value was compared with
	pass           bool
	started, ended bool // the action started or ended (by clear)
}

// step is Rules, Evaluation, of one rule for one subject: from the state
// before and the measure's value (nil when absent), the state after.
func (rule Rule) step(st ruleState, value any) (ruleState, stepResult) {
	v, present := asFloat(value)
	var r stepResult
	if !st.active {
		// Not active: count met conditions until `for`.
		r.limit = rule.Limit
		r.pass = present && holds(v, rule.Op, rule.Limit)
		if r.pass {
			st.count++
		} else {
			st.count = 0
		}
		if st.count >= rule.For {
			st.active, st.count = true, 0
			r.started = true
		}
		return st, r
	}
	// Active: clear on the other side of `clear`; an absent value never clears.
	r.limit = rule.Clear
	if above(rule.Op) {
		r.pass = present && v < rule.Clear
	} else {
		r.pass = present && v > rule.Clear
	}
	if r.pass {
		st.active = false
		r.ended = true
	}
	return st, r
}
