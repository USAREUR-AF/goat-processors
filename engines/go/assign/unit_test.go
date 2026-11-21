package assign

import (
	"math"
	"testing"

	"goat-correlator/engines/go/model"
)

func TestMembership(t *testing.T) {
	m := newMembership()
	var ev []Obj
	ev = m.start("a/1", ev)
	ev = m.start("b/1", ev)
	ev = m.join("a/2", "s1", ev)
	if m.Next != 3 || len(m.Systems["s1"]) != 2 || m.Systems["s1"][0] != "a/1" || m.Systems["s1"][1] != "a/2" {
		t.Fatalf("membership %+v", m)
	}
	if m.systemOf("a/2") != "s1" || m.systemOf("z/9") != "" {
		t.Error("systemOf")
	}
	c := m.copy()
	ev = m.leave("b/1", "assign", ev)
	if _, ok := m.Systems["s2"]; ok || len(c.Systems["s2"]) != 1 {
		t.Error("leave ends an empty track and leaves the copy alone")
	}
	if last := ev[len(ev)-1]; last["ev"] != "end" || last["system"] != "s2" {
		t.Errorf("events %v", ev)
	}
	ev = m.leave("a/1", "stale", nil)
	if len(ev) != 1 || m.Systems["s1"][0] != "a/2" {
		t.Errorf("leave from a track of two: %v %v", ev, m.Systems)
	}
	for i := 4; i <= 11; i++ {
		m.start("x/"+string(rune('a'+i)), nil)
	}
	order := m.order()
	for i := 1; i < len(order); i++ {
		if len(order[i]) < len(order[i-1]) {
			t.Errorf("order %v: s10 before s9", order)
		}
	}
	if !sameChoices([]Choice{{"a", "s1"}}, []Choice{{"a", "s1"}}) || sameChoices([]Choice{{"a", "s1"}}, nil) ||
		sameChoices([]Choice{{"a", "s1"}}, []Choice{{"a", "alone"}}) {
		t.Error("sameChoices")
	}
	h := History{[]Record{{Cost: 1, M: m}, {Cost: 2.5}}}
	if h.total() != 3.5 || len(History{}.latest(m).Systems) != len(m.Systems) {
		t.Error("History")
	}
}

func TestFusedAndCost(t *testing.T) {
	a := model.Axis{P: 0, V: 1, PP: 4, VV: 1}
	b := model.Axis{P: 10, V: 3, PP: 4, VV: 1}
	var s ivSum
	fe, fn := s.add(a, a).add(b, b).estimate()
	if fe.P != 5 || fe.PP != 2 || fe.V != 2 || fe.VV != 0.5 || fn != fe {
		t.Errorf("estimate %v %v", fe, fn)
	}
	if fe, _ := (ivSum{}).add(a, b).estimate(); fe != (model.Axis{P: 0, V: 1, PP: 4, VV: 1}) {
		t.Errorf("one member: %v", fe)
	}
	if c := costOf(model.Axis{P: 2, PP: 1}, model.Axis{P: 0, PP: 1}, model.Axis{P: 0, PP: 1}, model.Axis{P: 3, PP: 2}); c != 4.0/2+9.0/3 {
		t.Errorf("costOf %v", c)
	}
}

func TestBias(t *testing.T) {
	p := Params{HasBias: true, BiasSigma: 10, BiasFloor: 2, BiasGate: 9}
	st := BiasState{Var: 100}
	se := model.Axis{P: 0, V: 10, PP: 25}
	te := model.Axis{P: 5, V: 10, PP: 25}
	next, d2, ok := st.update(p, se, se, te, te)
	if !ok || d2 != 25.0/150*2 || next.Pairs != 1 || next.Var != 50 {
		t.Fatalf("update %+v %v %v", next, d2, ok)
	}
	if next.WEast != 1.0/50 || next.OEast != 5 || next.ONorth != 5 {
		t.Errorf("offset %+v", next)
	}
	// The floor holds var at f².
	for i := 0; i < 40; i++ {
		next, _, _ = next.update(p, se, se, te, te)
	}
	if next.Var != 4 {
		t.Errorf("var %v, want the floor 4", next.Var)
	}
	far := model.Axis{P: 500, PP: 25}
	if again, _, ok := next.update(p, se, se, far, far); ok || again != next {
		t.Error("a pair outside the gate changes the state")
	}
	// Moving: plus for B of the first source, minus for B of the second; var on pp.
	b := model.Axis{P: 1, V: 2, PP: 3}
	if e, _ := next.move(b, b, true, false); e.P != 1+next.OEast || e.PP != 3+next.Var {
		t.Errorf("move first %v", e)
	}
	if e, _ := next.move(b, b, false, false); e.P != 1-next.OEast {
		t.Errorf("move second %v", e)
	}
	tau := BiasState{OEast: 1, Tau: 0.5}
	if e, _ := tau.move(b, b, true, true); e.P != 1+(1-2*0.5) {
		t.Errorf("move with tau %v", e)
	}
	// Time offset: a source 0.2 s ahead seen at 10 m/s gives o - v*tau = -2.
	pt := p
	pt.HasTimeOffset, pt.TimeOffsetSigmaMs = true, 1000
	fit := BiasState{Var: 100}
	for i := 0; i < 200; i++ {
		v := float64(i%7) * 3
		s := model.Axis{P: 0, V: v, PP: 1}
		u := model.Axis{P: 1 - v*0.2, V: v, PP: 1}
		fit, _, _ = fit.update(pt, s, s, u, u)
	}
	if math.Abs(fit.Tau-0.2) > 0.01 || math.Abs(fit.OEast-1) > 0.05 {
		t.Errorf("fit tau %v o %v", fit.Tau, fit.OEast)
	}
	if fit.WEast != fit.Sums[0] {
		t.Error("w is S1 with time offset")
	}
}

// fakeCore is an assign.Core of fixed entities that never move.
type fakeCore struct {
	src  map[string]string
	pos  map[string]model.Axis
	gone map[string]bool
}

func (c *fakeCore) Keys() []string {
	var ks []string
	for _, k := range model.SortedKeys(c.src) {
		if !c.gone[k] {
			ks = append(ks, k)
		}
	}
	return ks
}
func (c *fakeCore) Source(k string) string                   { return c.src[k] }
func (c *fakeCore) LastTime(string) int64                    { return 0 }
func (c *fakeCore) Filter(k string) (model.Axis, model.Axis) { return c.pos[k], c.pos[k] }
func (c *fakeCore) Predicted(k string, _ int64) (model.Axis, model.Axis) {
	return c.pos[k], c.pos[k]
}
func (c *fakeCore) TimingVariance(string) (float64, float64) { return 0, 0 }
func (c *fakeCore) Hae(string) (float64, bool)               { return 0, false }
func (c *fakeCore) Intervals() (Obj, bool)                   { return nil, false }
func (c *fakeCore) Stale(k string, now int64) bool           { return now > 5000 && k == "a/2" }
func (c *fakeCore) Gate(a, b string, _ *[]Obj) bool          { return true }
func (c *fakeCore) Drop(k string)                            { c.gone[k] = true }
func (c *fakeCore) Frame() *model.Frame                      { return &model.Frame{Lat0: 50, Lon0: 8} }
func (c *fakeCore) EntitySnapshot(_ string, out Obj) Obj     { return out }

// TestWindowCommits: with a window of 2 the membership commits one tick
// late; a stale entity retires, then drops at its commit.
func TestWindowCommits(t *testing.T) {
	ax := func(p float64) model.Axis { return model.Axis{P: p, V: 0, PP: 1, VV: 1} }
	c := &fakeCore{src: map[string]string{"a/1": "a", "b/1": "b", "a/2": "a"},
		pos: map[string]model.Axis{"a/1": ax(0), "b/1": ax(0.5), "a/2": ax(1000)}, gone: map[string]bool{}}
	m := New(c, Params{NewCost: 9.21, KeepBonus: 2, Window: 2, Hypotheses: 2, HasRestart: true})
	for _, k := range []string{"a/1", "b/1", "a/2"} {
		m.Reported(k)
	}
	m.Restarted("b/1")
	ev, tr := m.Tick(1000)
	for _, e := range ev {
		if e["ev"] == "system" {
			t.Errorf("a system event before the first commit: %v", e)
		}
	}
	if len(tr) == 0 || len(m.histories) != 2 {
		t.Fatalf("trace %d, histories %d", len(tr), len(m.histories))
	}
	ev, _ = m.Tick(2000)
	systems := 0
	for _, e := range ev {
		if e["ev"] == "system" {
			systems++
		}
	}
	if systems != 2 {
		t.Errorf("after the commit: %v", ev)
	}
	if m.system["a/1"] != m.system["b/1"] || m.system["a/1"] == "" {
		t.Errorf("a/1 and b/1 in one system track: %v", m.system)
	}
	m.Tick(6000) // a/2 stale: retiring
	if !m.Retiring("a/2") {
		t.Fatal("a/2 not retiring")
	}
	snap := m.Snapshot()
	if r := snap["retiring"].([]any); len(r) != 1 || snap["histories"] == nil {
		t.Errorf("snapshot %v", snap)
	}
	m.Tick(7000) // the drop commits
	if m.Retiring("a/2") || !c.gone["a/2"] {
		t.Error("a/2 not dropped at its commit")
	}
}
