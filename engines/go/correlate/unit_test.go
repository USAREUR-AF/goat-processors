package correlate

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"goat-correlator/engines/go/model"
)

const confirmPack = `pack t
version 1
filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
gate mahalanobis gate=9.21
confirm_count 1
hold_failures 1
stale_ms 60000
`

const sprtLine = "sprt false=0.01 missed=0.01 pos_m=10000 vel_ms=300 hae_sigma_m=100\n"

const staleRateLine = "stale_rate factor=5 floor_ms=20000 ceiling_ms=60000 samples=3\n"

const assignPack = `pack t
version 1
method assign
filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
gate mahalanobis gate=18.42
new_cost 9.21
keep_bonus 2
stale_ms 60000
`

func report(src, uid string, t int64, lat, lon float64, extra ...any) map[string]any {
	r := map[string]any{"track.source_id": src, "uid": uid, "time_ms": json.Number(itoa(t)),
		"lat": json.Number(ftoa(lat)), "lon": json.Number(ftoa(lon))}
	for i := 0; i < len(extra); i += 2 {
		r[extra[i].(string)] = extra[i+1]
	}
	return r
}

func itoa(i int64) string   { b, _ := json.Marshal(i); return string(b) }
func ftoa(f float64) string { b, _ := json.Marshal(f); return string(b) }

func mustParse(t *testing.T, text string) *Pack {
	t.Helper()
	p, err := ParsePack(text)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestPackMethods(t *testing.T) {
	p := mustParse(t, confirmPack)
	if p.Method != "confirm" || len(p.Gate) != 1 || p.Gate[0].Num["gate"] != 9.21 || p.SameSource != "forbid" {
		t.Errorf("confirm pack = %+v", p)
	}
	p = mustParse(t, assignPack)
	if p.Method != "assign" || p.NewCost != 9.21 || p.KeepBonus != 2 || p.Window != 1 {
		t.Errorf("assign pack = %+v", p)
	}
	for name, text := range map[string]string{
		"unknown method":         strings.Replace(assignPack, "method assign", "method vote", 1),
		"assign refuses hold":    assignPack + "hold mahalanobis gate=1\n",
		"confirm refuses bias":   confirmPack + "bias sigma_m=1 floor_m=1 gate=1\n",
		"assign needs new_cost":  strings.Replace(assignPack, "new_cost 9.21\n", "", 1),
		"new_cost above 0":       strings.Replace(assignPack, "new_cost 9.21", "new_cost 0", 1),
		"repeated filter":        confirmPack + "filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n",
		"bad number":             strings.Replace(confirmPack, "gate=9.21", "gate=0x10", 1),
		"bad integer":            strings.Replace(confirmPack, "stale_ms 60000", "stale_ms 6e4", 1),
		"test without name":      confirmPack + "confirm\n",
		"same with a number":     confirmPack + "confirm same\n",
		"priority arity":         confirmPack + "priority a\n",
		"priority number":        confirmPack + "priority a b\n",
		"output":                 confirmPack + "output newest\n",
		"same_source":            confirmPack + "same_source maybe\n",
		"window below 1":         strings.Replace(assignPack, "stale_ms", "window 0\nstale_ms", 1),
		"maneuver range":         confirmPack + "maneuver accel_var=0.5 p_enter=0.1 p_leave=0.1\n",
		"maneuver parameter":     confirmPack + "maneuver accel_var=5 p_enter=0.1\n",
		"restart gate":           confirmPack + "restart gate=0\n",
		"time_offset needs bias": strings.Replace(assignPack, "stale_ms", "time_offset sigma_ms=10\nstale_ms", 1),
		"time_offset sigma":      strings.Replace(assignPack, "stale_ms", "bias sigma_m=10 floor_m=1 gate=9\ntime_offset sigma_ms=0\nstale_ms", 1),
		"margin needs k":         strings.Replace(assignPack, "stale_ms", "margin 1\nstale_ms", 1),
		"margin above 0":         strings.Replace(assignPack, "stale_ms", "window 2\nhypotheses 2\nmargin -1\nstale_ms", 1),
		"time_default twice":     confirmPack + "time_default s error_ms=1\ntime_default s state=drifting\n",
		"one value":              confirmPack + "pack t u\n",
		"filter range":           strings.Replace(confirmPack, "default_ce_m=50", "default_ce_m=0", 1),
		"window test retired":    confirmPack + "gate window multiplier=1 window_m=900 err_min_m=100 err_max_m=5000\n",
		"state probability":      confirmPack + "gate state probability=0.9 hae_sigma_m=100\n",
		"state hae_sigma_m":      confirmPack + "gate state probability=0.99 hae_sigma_m=0\n",
		"sprt with count":        strings.Replace(confirmPack, "hold_failures 1\n", sprtLine, 1),
		"sprt with hold":         strings.Replace(confirmPack, "confirm_count 1\nhold_failures 1\n", sprtLine+"hold mahalanobis gate=1\n", 1),
		"sprt false at half":     strings.Replace(confirmPack, "confirm_count 1\nhold_failures 1\n", strings.Replace(sprtLine, "false=0.01", "false=0.5", 1), 1),
		"sprt missing param":     strings.Replace(confirmPack, "confirm_count 1\nhold_failures 1\n", "sprt false=0.01 missed=0.01 pos_m=1 vel_ms=1\n", 1),
		"sprt with assign":       assignPack + sprtLine,
		"confirm needs count":    strings.Replace(confirmPack, "confirm_count 1\n", "", 1),
		"no staleness":           strings.Replace(confirmPack, "stale_ms 60000\n", "", 1),
		"both stalenesses":       confirmPack + staleRateLine,
		"stale_rate floor":       strings.Replace(confirmPack, "stale_ms 60000\n", "stale_rate factor=5 floor_ms=7 ceiling_ms=6 samples=9\n", 1),
		"stale_rate samples":     strings.Replace(confirmPack, "stale_ms 60000\n", "stale_rate factor=5 floor_ms=5 ceiling_ms=6 samples=0\n", 1),
		"stale_rate integer":     strings.Replace(confirmPack, "stale_ms 60000\n", "stale_rate factor=5 floor_ms=5.5 ceiling_ms=6 samples=1\n", 1),
		"stale_rate factor":      strings.Replace(confirmPack, "stale_ms 60000\n", "stale_rate factor=x floor_ms=5 ceiling_ms=6 samples=1\n", 1),
		"stale_rate parameter":   strings.Replace(confirmPack, "stale_ms 60000\n", "stale_rate factor=5 floor_ms=5 ceiling_ms=6\n", 1),
	} {
		if _, err := ParsePack(text); err == nil {
			t.Errorf("%s: loads", name)
		}
	}
	full := strings.Replace(assignPack, "stale_ms", "window 3\nhypotheses 2\nmargin 4\nbias sigma_m=10 floor_m=2 gate=9\ntime_offset sigma_ms=50\nrestart gate=30\nmaneuver accel_var=20 p_enter=0.05 p_leave=0.2\ntime_default s error_ms=100 state=drifting\nstale_ms", 1)
	p = mustParse(t, full)
	if !(p.HasMargin && p.HasBias && p.HasTimeOffset && p.HasRestart && p.HasManeuver && p.Window == 3 && p.Hypotheses == 2) {
		t.Errorf("full pack = %+v", p)
	}
	p = mustParse(t, strings.Replace(confirmPack, "confirm_count 1\nhold_failures 1\n", sprtLine, 1)+"output fused\n")
	if !p.HasSprt || p.Output != "fused" {
		t.Errorf("sprt pack = %+v", p)
	}
	if p = mustParse(t, confirmPack); p.Output != "fused" {
		t.Errorf("default output = %q", p.Output)
	}
	if _, err := LoadPack("testdata/none"); err == nil {
		t.Error("a missing pack loads")
	}
	if _, err := Load("testdata/none"); err == nil {
		t.Error("a missing pack loads")
	}
}

func pairOf(a, b *Entity, be, bn model.Axis) Pair { return Pair{A: a, B: b, BE: be, BN: bn} }

func TestTestKinds(t *testing.T) {
	kinds := DefaultTests()
	ent := func(e, n, ce float64, last map[string]any) *Entity {
		en := &Entity{Key: "k", East: model.Axis{P: e}, North: model.Axis{P: n}, Ce: ce, REast: 1, RNorth: 1}
		en.setLast(last)
		return en
	}
	a := ent(0, 0, 10, map[string]any{"course": 10.0, "speed_ms": 20.0, "hae": 100.0, "type": "a-f-G-U", "k": "x"})
	b := ent(0, 0, 30, map[string]any{"course": 350.0, "speed_ms": 10.0, "hae": 160.0, "type": "a-h-G", "k": "x"})
	p := pairOf(a, b, model.Axis{P: 3, PP: 3}, model.Axis{P: 4, PP: 8})
	run := func(name string, num map[string]float64, key string) Outcome {
		return kinds[name].Run(Test{Name: name, Num: num, Key: key}, p)
	}
	if o := run("distance", map[string]float64{"max_m": 5}, ""); o.Value != 5.0 || o.Pass {
		t.Errorf("distance %+v", o)
	}
	// state: A at rest with unit covariance, B's prediction at (3, 4) with
	// pp 3 and 8, no velocity difference and no cross terms; both have hae.
	a.East.PP, a.North.PP, a.East.VV, a.North.VV = 1, 1, 1, 1
	p.BE.VV, p.BN.VV = 1, 1
	o := run("state", map[string]float64{"probability": 0.99, "hae_sigma_m": 30}, "")
	want := 9.0/4 + 16.0/9 + 60.0*60/(2*30*30)
	if v := o.Value.(float64); math.Abs(v-want) > 1e-12 || o.Limit != 15.0863 || o.Extra["dof"] != int64(5) || !o.Pass {
		t.Errorf("state %+v", o)
	}
	if o := run("mahalanobis", map[string]float64{"gate": 5}, ""); o.Value != 9.0/4+16.0/9 || !o.Pass {
		t.Errorf("mahalanobis %+v", o)
	}
	if o := run("course", map[string]float64{"max_deg": 20, "min_speed_ms": 5}, ""); o.Value != 20.0 || !o.Pass {
		t.Errorf("course %+v", o)
	}
	if o := run("course", map[string]float64{"max_deg": 20, "min_speed_ms": 15}, ""); !o.Skipped {
		t.Errorf("course below min speed %+v", o)
	}
	if o := run("speed", map[string]float64{"max_pct": 40, "min_speed_ms": 5}, ""); o.Value != 50.0 || o.Pass {
		t.Errorf("speed %+v", o)
	}
	if o := run("altitude", map[string]float64{"max_m": 60}, ""); o.Value != 60.0 || !o.Pass {
		t.Errorf("altitude %+v", o)
	}
	if o := run("same", nil, "@env"); o.Value != "G" || !o.Pass {
		t.Errorf("same @env %+v", o)
	}
	if o := run("same", nil, "k"); !o.Pass {
		t.Errorf("same k %+v", o)
	}
	delete(b.Last, "hae")
	b.Last["speed_ms"] = 0.0
	a.Last["speed_ms"] = 0.0
	a.setLast(a.Last)
	b.setLast(b.Last)
	if o := run("altitude", map[string]float64{"max_m": 60}, ""); !o.Skipped {
		t.Errorf("altitude without hae %+v", o)
	}
	if o := run("state", map[string]float64{"probability": 0.95, "hae_sigma_m": 30}, ""); o.Limit != 9.4877 || o.Extra["dof"] != int64(4) || !o.Pass {
		t.Errorf("state without hae %+v", o)
	}
	if o := run("speed", map[string]float64{"max_pct": 40, "min_speed_ms": 0}, ""); o.Value != 0.0 || !o.Pass {
		t.Errorf("speed of two still tracks %+v", o)
	}
	b.Last["type"] = 5.0
	if o := run("same", nil, "@env"); o.Value != "G" || o.Limit != nil || o.Pass {
		t.Errorf("same @env without type %+v", o)
	}
}

func TestValuesEqual(t *testing.T) {
	for _, c := range []struct {
		x, y any
		eq   bool
	}{
		{json.Number("1"), 1.0, true}, {json.Number("1"), "1", false}, {nil, nil, true}, {nil, "x", false},
		{"a", "a", true}, {"a", 1.0, false}, {true, true, true}, {true, "true", false},
		{[]any{1.0, "a"}, []any{1.0, "a"}, true}, {map[string]any{"b": 1.0, "a": 2.0}, map[string]any{"a": 2.0, "b": 1.0}, true},
		{[]any{1.0}, []any{2.0}, false},
	} {
		if valuesEqual(c.x, c.y) != c.eq {
			t.Errorf("valuesEqual(%#v, %#v) = %v", c.x, c.y, !c.eq)
		}
	}
	if sameValue(&Entity{Last: map[string]any{"type": "a-f"}}, "@env") != nil {
		t.Error("@env of a short type")
	}
}

func TestIngestRejects(t *testing.T) {
	g := New(mustParse(t, confirmPack))
	ev, tr := g.Ingest(map[string]any{"uid": "u"})
	if ev[0]["reason"] != "missing:track.source_id" || len(tr) != 0 {
		t.Errorf("missing source: %v", ev)
	}
	g.Ingest(report("a", "1", 2000, 50, 8))
	ev, _ = g.Ingest(report("a", "1", 1000, 50, 8))
	if ev[0]["reason"] != "out-of-order" {
		t.Errorf("earlier report: %v", ev)
	}
	ev, _ = g.Ingest(report("a", "1", 2000, 50, 8))
	if len(ev) != 0 {
		t.Errorf("equal time report: %v", ev)
	}
}

// TestRestartConfirm: with method confirm, a report far outside the restart
// gate starts the filter again from it, with no event.
func TestRestartConfirm(t *testing.T) {
	g := New(mustParse(t, confirmPack+"restart gate=9\n"))
	g.Ingest(report("a", "1", 0, 50, 8))
	ev, tr := g.Ingest(report("a", "1", 1000, 51, 8))
	if len(ev) != 0 || len(tr) != 1 || tr[0]["test"] != "restart" || tr[0]["pass"] != false {
		t.Fatalf("events %v trace %v", ev, tr)
	}
	e := g.entities["a/1"]
	if e.East.PP != 2500 || e.North.P < 100000 {
		t.Errorf("filter after restart %+v", e.East)
	}
}

// TestTimeQualityResolution: the report's own key, then the pack's
// time_default, then 0 and coherent.
func TestTimeQualityResolution(t *testing.T) {
	defs := map[string]model.TimeDefault{"s": {HasError: true, ErrorMs: 50, HasState: true, State: "drifting"}}
	if te, st := timeQuality(defs, "s", map[string]any{}); te != 50 || st != "drifting" {
		t.Errorf("default: %v %v", te, st)
	}
	if te, st := timeQuality(defs, "s", map[string]any{"time_error_ms": json.Number("7"), "time_state": "free-running"}); te != 7 || st != "free-running" {
		t.Errorf("report: %v %v", te, st)
	}
	if te, st := timeQuality(defs, "t", map[string]any{}); te != 0 || st != "coherent" {
		t.Errorf("none: %v %v", te, st)
	}
}

// TestAssignCore exercises the engine as assign.Core.
func TestAssignCore(t *testing.T) {
	g := New(mustParse(t, assignPack))
	g.Ingest(report("a", "1", 1000, 50, 8, "hae", json.Number("120")))
	g.Ingest(report("b", "1", 1000, 50, 8.0001))
	c := core{g}
	if ks := c.Keys(); len(ks) != 2 || ks[0] != "a/1" {
		t.Errorf("Keys = %v", ks)
	}
	if h, ok := c.Hae("a/1"); !ok || h != 120 {
		t.Errorf("Hae = %v %v", h, ok)
	}
	if _, ok := c.Hae("b/1"); ok {
		t.Error("Hae of a report without one")
	}
	if c.Source("b/1") != "b" || c.LastTime("b/1") != 1000 || c.Frame() == nil || c.Stale("a/1", 2000) {
		t.Error("Core accessors")
	}
	var tr []Obj
	if !c.Gate("a/1", "b/1", &tr) || len(tr) != 1 {
		t.Errorf("Gate trace %v", tr)
	}
	e, n := c.Filter("a/1")
	pe, pn := c.Predicted("a/1", 1000)
	if pe != e || pn != n {
		t.Error("Predicted to the entity's own time is its filter")
	}
	if ve, vn := c.TimingVariance("a/1"); ve != 0 || vn != 0 {
		t.Error("TimingVariance without a time error")
	}
	ev, _ := g.Tick(1000)
	if len(ev) != 3 || ev[0]["ev"] != "start" || ev[1]["ev"] != "join" || ev[2]["ev"] != "system" {
		t.Fatalf("tick: %v", ev)
	}
	snap := g.Snapshot()
	if snap["entities"].(Obj)["a/1"].(Obj)["system"] != "s1" {
		t.Errorf("snapshot %v", snap)
	}
	c.Drop("a/1")
	if len(c.Keys()) != 1 {
		t.Error("Drop")
	}
}

// TestStaleRate: the last n intervals per source, the lower median times
// the factor between floor and ceiling, the ceiling with none; also with
// method assign, where the snapshot holds intervals.
func TestStaleRate(t *testing.T) {
	g := New(mustParse(t, strings.Replace(confirmPack, "stale_ms 60000\n", staleRateLine, 1)))
	if st := g.staleTime("a"); st != 60000 {
		t.Errorf("no interval: %v", st)
	}
	for _, tm := range []int64{0, 1000, 9000, 14000, 16000} {
		g.Ingest(report("a", "1", tm, 50, 8))
	}
	// intervals 1000, 8000, 5000, 2000: the last 3 are 8000 5000 2000, lower median 5000.
	iv := g.Snapshot()["intervals"].(Obj)["a"].([]any)
	if len(iv) != 3 || iv[0] != int64(8000) || g.staleTime("a") != 25000 {
		t.Errorf("intervals %v, stale time %v", iv, g.staleTime("a"))
	}
	g.Ingest(report("a", "1", 16100, 50, 8))
	g.Ingest(report("a", "1", 16200, 50, 8))
	if st := g.staleTime("a"); st != 20000 {
		t.Errorf("floor: %v", st)
	}
	ga := New(mustParse(t, strings.Replace(assignPack, "stale_ms 60000\n", staleRateLine, 1)))
	ga.Ingest(report("a", "1", 0, 50, 8))
	ga.Ingest(report("a", "1", 500, 50, 8))
	if iv := ga.Snapshot()["intervals"].(Obj)["a"].([]any); len(iv) != 1 || iv[0] != int64(500) {
		t.Errorf("assign intervals %v", iv)
	}
	if _, ok := New(mustParse(t, assignPack)).Snapshot()["intervals"]; ok {
		t.Error("intervals without stale_rate")
	}
}

// TestSprtForced: a pair with an L whose gate fails and whose same test
// fails is forced to lo and removed; in a group, a failing same test
// releases the member.
func TestSprtForced(t *testing.T) {
	text := strings.Replace(confirmPack, "confirm_count 1\nhold_failures 1\n", sprtLine+"gate same key=k\n", 1)
	g := New(mustParse(t, text))
	g.Ingest(report("a", "1", 0, 50, 8, "k", "x"))
	ev, _ := g.Ingest(report("b", "1", 0, 50, 8, "k", "x"))
	if len(ev) != 2 || ev[1]["ev"] != "correlate" {
		t.Fatalf("correlate: %v", ev)
	}
	ev, tr := g.Ingest(report("b", "1", 1000, 50, 8, "k", "y"))
	last := tr[len(tr)-1]
	if len(ev) != 2 || ev[0]["reason"] != "release" || last["increment"] != nil || last["d2"] != nil {
		t.Fatalf("release: %v %v", ev, tr)
	}
	if len(g.llr) != 0 {
		t.Errorf("llr after release %v", g.llr)
	}
	// Ungrouped again: a pair with an L that fails the gate (far away) but
	// passes the same test adds evidence; one that fails the same test is forced.
	g.llr[pairKey("a/1", "b/1")] = 1
	_, tr = g.Ingest(report("b", "1", 2000, 51, 8, "k", "x"))
	if last := tr[len(tr)-1]; last["stage"] != "sprt" || last["increment"] == nil {
		t.Errorf("evidence after a failed gate: %v", tr)
	}
	g.llr[pairKey("a/1", "b/1")] = 1
	_, tr = g.Ingest(report("b", "1", 3000, 51, 8, "k", "y"))
	if last := tr[len(tr)-1]; last["increment"] != nil || len(g.llr) != 0 {
		t.Errorf("forced after a failed gate: %v %v", tr, g.llr)
	}
	_, tr = g.Ingest(report("b", "1", 4000, 51, 8, "k", "y"))
	if len(tr) == 0 || tr[len(tr)-1]["stage"] == "sprt" {
		t.Errorf("no update without an L: %v", tr)
	}
	// Stale entities take their pairs' L with them.
	g.llr[pairKey("a/1", "b/1")] = 1
	g.Tick(100000)
	if len(g.llr) != 0 || len(g.entities) != 0 {
		t.Errorf("after staleness: %v", g.llr)
	}
}
