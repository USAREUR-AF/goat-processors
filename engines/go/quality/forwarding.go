package quality

import (
	"math"
)

// inForce returns the rules whose actions are in force for a report of the
// entity from source, other than alert, in pack order (spec: Rules, Actions).
// A source rule is taken for the report's own track.source_id, which differs
// from the entity's source when keys collide (spec: Reports).
func (g *Engine) inForce(e *entity, source string) []Rule {
	var out []Rule
	for i, rule := range g.pack.Rules {
		subject := e.key
		if rule.Scope == "source" {
			subject = source
		}
		if st := g.states[i][subject]; st != nil && st.active && rule.Action != "alert" {
			out = append(out, rule)
		}
	}
	return out
}

// forward builds the pass event (spec: Forwarding).
func (g *Engine) forward(e *entity, report map[string]any, r reading) Obj {
	rules := g.inForce(e, r.source)
	names := []any{}
	var withheld, downgrade, mark bool
	for _, rule := range rules {
		names = append(names, rule.Name)
		switch rule.Action {
		case "drop":
			withheld = true
		case "downgrade":
			downgrade = true
		case "mark":
			mark = true
		}
	}
	ev := Obj{"ev": "pass", "entity": e.key, "rules": names, "withheld": withheld}
	if withheld {
		return ev
	}

	// The report exactly as received, with the changes below.
	out := make(map[string]any, len(report))
	for k, v := range report {
		out[k] = v
	}
	if downgrade {
		x := r.ce // the valid ce, or default_ce_m
		for _, rule := range rules {
			if rule.Action == "downgrade" {
				x = x * rule.Factor
			}
		}
		if math.IsInf(x, 1) {
			x = math.MaxFloat64 // the largest finite binary64
		}
		out["ce"] = x
	}
	if mark {
		marks := []any{}
		if list, ok := report["quality.marks"].([]any); ok && allStrings(list) {
			marks = append(marks, list...)
		}
		for _, rule := range rules {
			if rule.Action == "mark" && !containsAny(marks, rule.Name) {
				marks = append(marks, rule.Name)
			}
		}
		out["quality.marks"] = marks
	}
	ev["report"] = out
	return ev
}

func allStrings(list []any) bool {
	for _, x := range list {
		if _, ok := x.(string); !ok {
			return false
		}
	}
	return true
}

func containsAny(list []any, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
