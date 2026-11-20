package correlate

import (
	"encoding/json"
	"math"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Tests (spec/correlate.md: Tests): each test between entity A and entity B
// predicted to A's time gives one trace record.

func record(stage string, a, b *Entity, test string, value, limit any, pass bool) Obj {
	return trace.Record(stage, a.Key, b.Key, test, value, limit, pass)
}

// d2 is the squared statistical distance of A's filter from B's prediction
// (spec: Tests): B's predicted pp holds B's timing variance, and r_a is A's
// last measurement variance on each axis (ce_a² when its time error was 0).
func (g *Engine) d2(a, b *Entity) float64 {
	be, bn := g.predictedFor(b, a)
	return model.Mahalanobis(a.East.P, a.North.P, be, bn, a.REast, a.RNorth)
}

// runTests runs tests in order, stopping at the first failure, and reports whether all passed.
func (g *Engine) runTests(stage string, tests []Test, a, b *Entity, trace *[]Obj) bool {
	for _, t := range tests {
		rec := g.runTest(stage, t, a, b)
		*trace = append(*trace, rec)
		if !rec["pass"].(bool) {
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

// runTest runs one test between A and B predicted to A's time (spec: Tests table).
func (g *Engine) runTest(stage string, t Test, a, b *Entity) Obj {
	skipped := func() Obj { return trace.Skipped(stage, a.Key, b.Key, t.Name) }
	be, bn := g.predictedFor(b, a)
	dist := math.Hypot(a.East.P-be.P, a.North.P-bn.P)
	switch t.Name {
	case "distance":
		lim := t.Num["max_m"]
		return record(stage, a, b, t.Name, dist, lim, dist < lim)
	case "window":
		lo, hi := t.Num["err_min_m"], t.Num["err_max_m"]
		ea, eb := clamp(a.Ce, lo, hi), clamp(b.Ce, lo, hi)
		lim := t.Num["multiplier"]*math.Sqrt(ea*ea+eb*eb) + t.Num["window_m"]
		return record(stage, a, b, t.Name, dist, lim, dist < lim)
	case "mahalanobis":
		d2 := g.d2(a, b)
		lim := t.Num["gate"]
		return record(stage, a, b, t.Name, d2, lim, d2 < lim)
	case "course", "speed":
		ca, okCa := a.num("course")
		cb, okCb := b.num("course")
		sa, okSa := a.num("speed_ms")
		sb, okSb := b.num("speed_ms")
		min := t.Num["min_speed_ms"]
		if !okSa || !okSb || sa < min || sb < min || (t.Name == "course" && (!okCa || !okCb)) {
			return skipped()
		}
		if t.Name == "course" {
			d := math.Abs(ca - cb)
			v := math.Min(d, 360-d)
			lim := t.Num["max_deg"]
			return record(stage, a, b, t.Name, v, lim, v <= lim)
		}
		slow, fast := math.Min(sa, sb), math.Max(sa, sb)
		v := 0.0
		if fast != 0 {
			v = math.Abs(1-slow/fast) * 100
		}
		lim := t.Num["max_pct"]
		return record(stage, a, b, t.Name, v, lim, v <= lim)
	case "altitude":
		ha, okA := a.num("hae")
		hb, okB := b.num("hae")
		if !okA || !okB {
			return skipped()
		}
		v := math.Abs(ha - hb)
		lim := t.Num["max_m"]
		return record(stage, a, b, t.Name, v, lim, v <= lim)
	case "same":
		va, vb := sameValue(a, t.Key), sameValue(b, t.Key)
		return record(stage, a, b, t.Name, va, vb, valuesEqual(va, vb))
	}
	panic("unknown test " + t.Name)
}
