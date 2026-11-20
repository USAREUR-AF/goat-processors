package fuse

import (
	"encoding/json"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
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

// attributeRule is one row of the attribute rules table: which values are
// candidates, and the winner among one or more candidates in key order.
type attributeRule struct {
	usable func(v any) bool
	decide func(g *Engine, cands []candidate) *candidate
}

// scalar is a string, a number or a boolean.
func scalar(v any) bool {
	switch v.(type) {
	case string, bool:
		return true
	}
	return isNumber(v)
}

// attributeRules is the Attributes table: candidates are strings, numbers
// and booleans for priority, latest and majority, numbers for max and min.
// Every rule but majority keeps the earlier candidate on a tie. Adding a
// rule is one row.
var attributeRules = map[string]attributeRule{
	"priority": {scalar, firstBest(func(g *Engine, c, w candidate) bool { return g.rankOrder(c.Entity) < g.rankOrder(w.Entity) })},
	"latest":   {scalar, firstBest(func(_ *Engine, c, w candidate) bool { return c.LastTime > w.LastTime })},
	"majority": {scalar, func(_ *Engine, cands []candidate) *candidate { return majority(cands) }},
	"max":      {isNumber, firstBest(func(_ *Engine, c, w candidate) bool { return num(c.value) > num(w.value) })},
	"min":      {isNumber, firstBest(func(_ *Engine, c, w candidate) bool { return num(c.value) < num(w.value) })},
}

// firstBest is a winner rule: the first candidate no later one beats.
func firstBest(better func(g *Engine, c, w candidate) bool) func(*Engine, []candidate) *candidate {
	return func(g *Engine, cands []candidate) *candidate {
		w := &cands[0]
		for i := 1; i < len(cands); i++ {
			if better(g, cands[i], *w) {
				w = &cands[i]
			}
		}
		return w
	}
}

// equal is Attributes, equality for majority: strings by bytes, numbers by value,
// booleans by value; a string, a number and a boolean are never equal.
func equal(x, y any) bool {
	if isNumber(x) || isNumber(y) {
		if !isNumber(x) || !isNumber(y) {
			return false
		}
		fx, _ := model.ToFloat(x)
		fy, _ := model.ToFloat(y)
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

func num(v any) float64 { f, _ := model.ToFloat(v); return f }

// attribute decides one attribute for a group and appends its trace record
// (Trace, item 3). ok is false when there is no candidate.
func (g *Engine) attribute(name string, a Attribute, members []member, tr *[]Obj) (winner string, value any, ok bool) {
	rule := attributeRules[a.Rule]
	var cands []candidate
	records := []any{}
	for i := range members {
		m := &members[i]
		v, present := m.Report[a.Key]
		if !present || !rule.usable(v) {
			continue
		}
		cands = append(cands, candidate{m, v})
		records = append(records, trace.AttributeCandidate(m.Key, v, m.LastTime, g.rank(m.Entity)))
	}

	var w *candidate
	if len(cands) > 0 {
		w = rule.decide(g, cands)
	}
	var winnerKey, winnerValue any
	if w != nil {
		winnerKey, winnerValue = w.Key, w.value
	}
	*tr = append(*tr, trace.Attribute(model.OrNull(name), a.Key, a.Rule, records, winnerKey, winnerValue))
	if w == nil {
		return "", nil, false
	}
	return w.Key, w.value, true
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
