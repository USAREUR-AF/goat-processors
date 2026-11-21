package correlate

import (
	"encoding/json"
	"fmt"
	"math"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Tests (spec/correlate.md: Tests): each test between entity A and entity B
// predicted to A's time gives one trace record. A test is a pure function
// of the pair: A's state and B's prediction.

// Pair is what every test between A and B reads: both entities (read
// only) and B's prediction to A's time, with B's timing variance and moved
// into A's frame (Engine.predictedFor).
type Pair struct {
	A, B   *Entity
	BE, BN model.Axis
}

// Dist is the plane distance from A's filter to B's prediction.
func (p Pair) Dist() float64 { return math.Hypot(p.A.East.P-p.BE.P, p.A.North.P-p.BN.P) }

// D2 is the squared statistical distance of A's filter from B's prediction:
// B's predicted pp holds B's timing variance, and r_a is A's last
// measurement variance on each axis (ce_a² when its time error was 0).
func (p Pair) D2() float64 {
	return model.Mahalanobis(p.A.East.P, p.A.North.P, p.BE, p.BN, p.A.REast, p.A.RNorth)
}

// Outcome is what one test gives: its value, limit and pass, or Skipped
// (the record then has value and limit null, pass true and "skipped").
// Extra holds keys a test adds to its record (the state test's dof).
type Outcome struct {
	Value, Limit any
	Pass         bool
	Skipped      bool
	Extra        Obj
}

// TestKind is one row of the Tests table: its parameters, all required,
// the check of their values at load (nil: any value that parses), and its
// function, pure in the test's parameters and the pair.
type TestKind struct {
	Params []string
	Text   bool // the parameters are text (same), not numbers
	Check  func(t Test) error
	Run    func(t Test, p Pair) Outcome
}

// State is the full-state statistic of the pair (Tests, the state test)
// without the height term: each axis's dp, dv, sums, det and q.
func (p Pair) State() (east, north model.StateAxis) {
	return model.StateOf(p.A.East, p.A.TimeVarEast, p.BE), model.StateOf(p.A.North, p.A.TimeVarNorth, p.BN)
}

// haeDiff is hae_a - hae_b when both last reports have hae.
func (p Pair) haeDiff() (float64, bool) {
	ha, okA := p.A.num("hae")
	hb, okB := p.B.num("hae")
	return ha - hb, okA && okB
}

func record(stage string, a, b *Entity, test string, value, limit any, pass bool) Obj {
	return trace.Record(stage, a.Key, b.Key, test, value, limit, pass)
}

// pairOf is the pair of A and B.
func (g *Engine) pairOf(a, b *Entity) Pair {
	be, bn := g.predictedFor(b, a)
	return Pair{a, b, be, bn}
}

// d2 is Pair.D2 for A and B (spec: Tests, also the rank of Association).
func (g *Engine) d2(a, b *Entity) float64 { return g.pairOf(a, b).D2() }

// runTests runs tests in order, stopping at the first failure, and reports whether all passed.
func (g *Engine) runTests(stage string, tests []Test, a, b *Entity, tr *[]Obj) bool {
	if len(tests) == 0 {
		return true
	}
	pr := g.pairOf(a, b)
	for _, t := range tests {
		o := t.kind.Run(t, pr)
		if o.Skipped {
			*tr = append(*tr, trace.Skipped(stage, a.Key, b.Key, t.Name))
			continue
		}
		rec := record(stage, a, b, t.Name, o.Value, o.Limit, o.Pass)
		for k, v := range o.Extra {
			rec[k] = v
		}
		*tr = append(*tr, rec)
		if !o.Pass {
			return false
		}
	}
	return true
}

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

// checkState is the load check of the state test (correlate.md Pack):
// probability one of the table's values, hae_sigma_m above 0.
func checkState(t Test) error {
	if _, ok := model.ChiSquareLimit(t.Num["probability"], 4); !ok {
		return fmt.Errorf("state: probability %v is not in the table", t.Num["probability"])
	}
	if !(t.Num["hae_sigma_m"] > 0) {
		return fmt.Errorf("state: hae_sigma_m must be above 0")
	}
	return nil
}

// DefaultTests is the Tests table of spec/correlate.md: a new map at each
// call, so a caller may add a kind to its own copy (Registry).
func DefaultTests() map[string]TestKind {
	return map[string]TestKind{
		"distance": {Params: []string{"max_m"}, Run: func(t Test, p Pair) Outcome {
			dist, lim := p.Dist(), t.Num["max_m"]
			return Outcome{Value: dist, Limit: lim, Pass: dist < lim}
		}},
		"mahalanobis": {Params: []string{"gate"}, Run: func(t Test, p Pair) Outcome {
			d2, lim := p.D2(), t.Num["gate"]
			return Outcome{Value: d2, Limit: lim, Pass: d2 < lim}
		}},
		"course": {Params: []string{"max_deg", "min_speed_ms"}, Run: func(t Test, p Pair) Outcome {
			ca, okCa := p.A.num("course")
			cb, okCb := p.B.num("course")
			sa, okSa := p.A.num("speed_ms")
			sb, okSb := p.B.num("speed_ms")
			min := t.Num["min_speed_ms"]
			if !okSa || !okSb || sa < min || sb < min || !okCa || !okCb {
				return Outcome{Skipped: true}
			}
			d := math.Abs(ca - cb)
			v := math.Min(d, 360-d)
			lim := t.Num["max_deg"]
			return Outcome{Value: v, Limit: lim, Pass: v <= lim}
		}},
		"speed": {Params: []string{"max_pct", "min_speed_ms"}, Run: func(t Test, p Pair) Outcome {
			sa, okSa := p.A.num("speed_ms")
			sb, okSb := p.B.num("speed_ms")
			min := t.Num["min_speed_ms"]
			if !okSa || !okSb || sa < min || sb < min {
				return Outcome{Skipped: true}
			}
			slow, fast := math.Min(sa, sb), math.Max(sa, sb)
			v := 0.0
			if fast != 0 {
				v = math.Abs(1-slow/fast) * 100
			}
			lim := t.Num["max_pct"]
			return Outcome{Value: v, Limit: lim, Pass: v <= lim}
		}},
		"altitude": {Params: []string{"max_m"}, Run: func(t Test, p Pair) Outcome {
			ha, okA := p.A.num("hae")
			hb, okB := p.B.num("hae")
			if !okA || !okB {
				return Outcome{Skipped: true}
			}
			v := math.Abs(ha - hb)
			lim := t.Num["max_m"]
			return Outcome{Value: v, Limit: lim, Pass: v <= lim}
		}},
		"state": {Params: []string{"probability", "hae_sigma_m"}, Check: checkState, Run: func(t Test, p Pair) Outcome {
			e, n := p.State()
			d2, dof := e.Q+n.Q, 4
			if dh, ok := p.haeDiff(); ok {
				h := t.Num["hae_sigma_m"]
				d2, dof = d2+dh*dh/(2*h*h), 5
			}
			lim, _ := model.ChiSquareLimit(t.Num["probability"], dof)
			return Outcome{Value: d2, Limit: lim, Pass: d2 < lim, Extra: Obj{"dof": int64(dof)}}
		}},
		"same": {Params: []string{"key"}, Text: true, Run: func(t Test, p Pair) Outcome {
			va, vb := sameValue(p.A, t.Key), sameValue(p.B, t.Key)
			return Outcome{Value: va, Limit: vb, Pass: valuesEqual(va, vb)}
		}},
	}
}
