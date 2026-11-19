package fuse

import (
	"encoding/json"

	correlator "goat-correlator/engines/go"
)

// Attributes: one rule per `attribute` line, over the group's candidates.

// candidate is a member whose last report holds a usable value for the key.
type candidate struct {
	*member
	value any // as the report holds it
}

// isNumber is true for a JSON number (not a boolean).
func isNumber(v any) bool {
	switch v.(type) {
	case json.Number, float64, int, int64:
		return true
	}
	return false
}

// usable is Attributes, candidates: a string, a number or a boolean for priority,
// latest and majority; a number for max and min.
func usable(rule string, v any) bool {
	if rule == "max" || rule == "min" {
		return isNumber(v)
	}
	switch v.(type) {
	case string, bool:
		return true
	}
	return isNumber(v)
}

// equal is Attributes, equality for majority: strings by bytes, numbers by value,
// booleans by value; a string, a number and a boolean are never equal.
func equal(x, y any) bool {
	if isNumber(x) || isNumber(y) {
		if !isNumber(x) || !isNumber(y) {
			return false
		}
		fx, _ := correlator.ToFloat(x)
		fy, _ := correlator.ToFloat(y)
		return fx == fy
	}
	switch xv := x.(type) {
	case string:
		yv, ok := y.(string)
		return ok && xv == yv
	case bool:
		yv, ok := y.(bool)
		return ok && xv == yv
	}
	return false
}

func num(v any) float64 { f, _ := correlator.ToFloat(v); return f }

// attribute decides one attribute for a group and appends its trace record
// (Trace, item 3). ok is false when there is no candidate.
func (g *Engine) attribute(name string, a Attribute, members []member, trace *[]Obj) (winner string, value any, ok bool) {
	var cands []candidate
	records := []any{}
	for i := range members {
		m := &members[i]
		v, present := m.Report[a.Key]
		if !present || !usable(a.Rule, v) {
			continue
		}
		cands = append(cands, candidate{m, v})
		records = append(records, Obj{"member": m.Key, "value": v, "time_ms": m.LastTime, "rank": g.rank(m.Entity)})
	}

	var w *candidate
	if len(cands) > 0 {
		w = g.decide(a.Rule, cands)
	}
	rec := Obj{"stage": "attribute", "group": nameOrNull(name), "key": a.Key, "rule": a.Rule,
		"candidates": records, "winner": nil, "value": nil}
	if w != nil {
		rec["winner"], rec["value"] = w.Key, w.value
	}
	*trace = append(*trace, rec)
	if w == nil {
		return "", nil, false
	}
	return w.Key, w.value, true
}

// decide applies the rule's Winner column to one or more candidates in key order.
// Every rule except majority keeps the earlier candidate on a tie.
func (g *Engine) decide(rule string, cands []candidate) *candidate {
	if rule == "majority" {
		return majority(cands)
	}
	better := map[string]func(c, w candidate) bool{
		"priority": func(c, w candidate) bool { return g.rankOrder(c.Entity) < g.rankOrder(w.Entity) },
		"latest":   func(c, w candidate) bool { return c.LastTime > w.LastTime },
		"max":      func(c, w candidate) bool { return num(c.value) > num(w.value) },
		"min":      func(c, w candidate) bool { return num(c.value) < num(w.value) },
	}[rule]
	w := &cands[0]
	for i := 1; i < len(cands); i++ {
		if better(cands[i], *w) {
			w = &cands[i]
		}
	}
	return w
}

// majority counts equal values; the value held by the most candidates wins, a tie
// in count goes to the value whose first holder comes first in key order, and the
// winner is that first holder.
func majority(cands []candidate) *candidate {
	type tally struct {
		first *candidate // first holder in key order
		count int
	}
	var values []*tally // in order of first holder
	for i := range cands {
		c := &cands[i]
		var t *tally
		for _, v := range values {
			if equal(v.first.value, c.value) {
				t = v
				break
			}
		}
		if t == nil {
			t = &tally{first: c}
			values = append(values, t)
		}
		t.count++
	}
	best := values[0]
	for _, t := range values[1:] {
		if t.count > best.count {
			best = t
		}
	}
	return best.first
}
