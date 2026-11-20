package correlate

import (
	"encoding/json"
	"math"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Tests (spec/correlate.md: Tests): each test between entity A and entity B
// predicted to A's time gives one trace record. A test is a pure function
// of the pair: A's state and B's prediction.

// pair is what every test between A and B reads: both entities (read only)
// and B's prediction to A's time, with B's timing variance and moved into
// A's frame (Engine.predictedFor).
type pair struct {
	a, b   *Entity
	be, bn model.Axis
}

// dist is the plane distance from A's filter to B's prediction.
func (p pair) dist() float64 { return math.Hypot(p.a.East.P-p.be.P, p.a.North.P-p.bn.P) }

// d2 is the squared statistical distance of A's filter from B's prediction:
// B's predicted pp holds B's timing variance, and r_a is A's last
// measurement variance on each axis (ce_a² when its time error was 0).
func (p pair) d2() float64 {
	return model.Mahalanobis(p.a.East.P, p.a.North.P, p.be, p.bn, p.a.REast, p.a.RNorth)
}

// outcome is what one test gives: its value, limit and pass, or skipped.
type outcome struct {
	value, limit any
	pass         bool
	skipped      bool
}

var skip = outcome{skipped: true}

func record(stage string, a, b *Entity, test string, value, limit any, pass bool) Obj {
	return trace.Record(stage, a.Key, b.Key, test, value, limit, pass)
}

// pairOf is the pair of A and B.
func (g *Engine) pairOf(a, b *Entity) pair {
	be, bn := g.predictedFor(b, a)
	return pair{a, b, be, bn}
}

// d2 is pair.d2 for A and B (spec: Tests, also the rank of Association).
func (g *Engine) d2(a, b *Entity) float64 { return g.pairOf(a, b).d2() }

// runTests runs tests in order, stopping at the first failure, and reports whether all passed.
func (g *Engine) runTests(stage string, tests []Test, a, b *Entity, tr *[]Obj) bool {
	if len(tests) == 0 {
		return true
	}
	pr := g.pairOf(a, b)
	for _, t := range tests {
		o := testKinds[t.Name].run(t, pr)
		if o.skipped {
			*tr = append(*tr, trace.Skipped(stage, a.Key, b.Key, t.Name))
			continue
		}
		*tr = append(*tr, record(stage, a, b, t.Name, o.value, o.limit, o.pass))
		if !o.pass {
			return false
		}
	}
	return true
}

func clamp(x, lo, hi float64) float64 { return math.Min(math.Max(x, lo), hi) }

// sameValue returns the value a "same" test compares; "@env" is the third element of type.
func sameValue(e *Entity, key string) any {
	if key == "@env" {
		s, ok := e.Last["type"].(string)
		if !ok {
			return nil
		}
		env, ok := model.Environment(s)
		if !ok {
			return nil
		}
		return env
	}
	return e.Last[key]
}

func valuesEqual(x, y any) bool {
	if fx, ok := model.ToFloat(x); ok {
		fy, ok := model.ToFloat(y)
		return ok && fx == fy
	}
	switch xv := x.(type) {
	case nil:
		return y == nil
	case string:
		yv, ok := y.(string)
		return ok && xv == yv
	case bool:
		yv, ok := y.(bool)
		return ok && xv == yv
	}
	xb, _ := json.Marshal(x)
	yb, _ := json.Marshal(y)
	return string(xb) == string(yb)
}

// testKind is one row of the Tests table: its parameters and its function.
type testKind struct {
	params []string // the parameters, all required
	text   bool     // the parameters are text, not numbers (same)
	run    func(t Test, p pair) outcome
}

// testKinds is the Tests table.
var testKinds = map[string]testKind{
	"distance": {params: []string{"max_m"}, run: func(t Test, p pair) outcome {
		dist, lim := p.dist(), t.Num["max_m"]
		return outcome{dist, lim, dist < lim, false}
	}},
	"window": {params: []string{"multiplier", "window_m", "err_min_m", "err_max_m"}, run: func(t Test, p pair) outcome {
		lo, hi := t.Num["err_min_m"], t.Num["err_max_m"]
		ea, eb := clamp(p.a.Ce, lo, hi), clamp(p.b.Ce, lo, hi)
		lim := t.Num["multiplier"]*math.Sqrt(ea*ea+eb*eb) + t.Num["window_m"]
		dist := p.dist()
		return outcome{dist, lim, dist < lim, false}
	}},
	"mahalanobis": {params: []string{"gate"}, run: func(t Test, p pair) outcome {
		d2, lim := p.d2(), t.Num["gate"]
		return outcome{d2, lim, d2 < lim, false}
	}},
	"course": {params: []string{"max_deg", "min_speed_ms"}, run: func(t Test, p pair) outcome {
		ca, okCa := p.a.num("course")
		cb, okCb := p.b.num("course")
		sa, okSa := p.a.num("speed_ms")
		sb, okSb := p.b.num("speed_ms")
		min := t.Num["min_speed_ms"]
		if !okSa || !okSb || sa < min || sb < min || !okCa || !okCb {
			return skip
		}
		d := math.Abs(ca - cb)
		v := math.Min(d, 360-d)
		lim := t.Num["max_deg"]
		return outcome{v, lim, v <= lim, false}
	}},
	"speed": {params: []string{"max_pct", "min_speed_ms"}, run: func(t Test, p pair) outcome {
		sa, okSa := p.a.num("speed_ms")
		sb, okSb := p.b.num("speed_ms")
		min := t.Num["min_speed_ms"]
		if !okSa || !okSb || sa < min || sb < min {
			return skip
		}
		slow, fast := math.Min(sa, sb), math.Max(sa, sb)
		v := 0.0
		if fast != 0 {
			v = math.Abs(1-slow/fast) * 100
		}
		lim := t.Num["max_pct"]
		return outcome{v, lim, v <= lim, false}
	}},
	"altitude": {params: []string{"max_m"}, run: func(t Test, p pair) outcome {
		ha, okA := p.a.num("hae")
		hb, okB := p.b.num("hae")
		if !okA || !okB {
			return skip
		}
		v := math.Abs(ha - hb)
		lim := t.Num["max_m"]
		return outcome{v, lim, v <= lim, false}
	}},
	"same": {params: []string{"key"}, text: true, run: func(t Test, p pair) outcome {
		va, vb := sameValue(p.a, t.Key), sameValue(p.b, t.Key)
		return outcome{va, vb, valuesEqual(va, vb), false}
	}},
}
