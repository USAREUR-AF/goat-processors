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
		v, present := asFloat(value)
		var limit float64
		var pass bool
		if !st.active {
			// Not active: count met conditions until `for`.
			limit = rule.Limit
			pass = present && holds(v, rule.Op, rule.Limit)
			if pass {
				st.count++
			} else {
				st.count = 0
			}
			if st.count >= rule.For {
				st.active, st.count = true, 0
				events = append(events, Obj{"ev": "action-start", "rule": rule.Name, "scope": scope,
					"subject": subject, "action": rule.Action, "value": value})
			}
		} else {
			// Active: clear on the other side of `clear`; an absent value never clears.
			limit = rule.Clear
			if above(rule.Op) {
				pass = present && v < rule.Clear
			} else {
				pass = present && v > rule.Clear
			}
			if pass {
				st.active = false
				events = append(events, Obj{"ev": "action-end", "rule": rule.Name, "scope": scope,
					"subject": subject, "action": rule.Action, "reason": "clear", "value": value})
			}
		}
		tr = append(tr, trace.QualityRule(rule.Name, subject, rule.Measure, value, limit, pass, st.count, st.active))
	}
	return events, tr
}
