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
		return &Entity{Key: "k", East: model.Axis{P: e}, North: model.Axis{P: n}, Ce: ce, REast: 1, RNorth: 1, Last: last}
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
	o := run("window", map[string]float64{"multiplier": 1, "window_m": 0, "err_min_m": 20, "err_max_m": 40}, "")
	if lim := o.Limit.(float64); !(math.Abs(lim-math.Sqrt(20*20+30*30)) < 1e-12) || !o.Pass {
		t.Errorf("window %+v", o)
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
	if o := run("altitude", map[string]float64{"max_m": 60}, ""); !o.Skipped {
		t.Errorf("altitude without hae %+v", o)
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
