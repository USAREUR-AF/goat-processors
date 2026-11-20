package model

import (
	"encoding/json"
	"math"
	"strconv"
	"testing"
)

func near(a, b float64) bool { return math.Abs(a-b) <= 1e-9*math.Max(1, math.Abs(b)) }

func TestWrap180(t *testing.T) {
	for _, c := range []struct{ in, want float64 }{{0, 0}, {180, 180}, {-180, 180}, {181, -179}, {-181, 179}, {540, 180}, {-540, 180}, {720, 0}} {
		if got := Wrap180(c.in); got != c.want {
			t.Errorf("Wrap180(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestFrameRoundTrip(t *testing.T) {
	f := Frame{Lat0: 50, Lon0: 179.9}
	e, n := f.ToPlane(50.01, -179.95) // across the antimeridian
	if !(e > 0 && n > 0) {
		t.Fatalf("ToPlane = %v, %v: want east and north of the reference", e, n)
	}
	lat, lon := f.ToDegrees(e, n)
	if !near(lat, 50.01) || !near(lon, -179.95) {
		t.Errorf("round trip gives %v, %v", lat, lon)
	}
	if e, n := f.ToPlane(50, 179.9); e != 0 || n != 0 {
		t.Errorf("the reference is at %v, %v", e, n)
	}
}

func TestVelocityCourse(t *testing.T) {
	for _, course := range []float64{0, 45, 90, 179.5, 180, 270, 359} {
		ve, vn := Velocity(course, 10)
		if got := Course(ve, vn); !near(got, course) {
			t.Errorf("Course(Velocity(%v)) = %v", course, got)
		}
		if s := math.Hypot(ve, vn); !near(s, 10) {
			t.Errorf("speed %v", s)
		}
	}
	if c := Course(0, 0); c != 0 {
		t.Errorf("Course(0, 0) = %v", c)
	}
	if c := Course(-1e-300, 1); c < 0 || c >= 360 {
		t.Errorf("Course near 360 = %v, want in [0, 360)", c)
	}
}

func TestAxisSteps(t *testing.T) {
	a := Axis{P: 10, V: 2, PP: 4, PV: 1, VV: 3}
	if p := a.Predict(0, 5); p != a {
		t.Errorf("Predict(0) = %v", p)
	}
	p := a.Predict(2, 1)
	want := Axis{P: 14, V: 2, PP: 4 + 2*2*1 + 2*2*3 + 1*16.0/4, PV: 1 + 2*3 + 1*8.0/2, VV: 3 + 4}
	if p != want {
		t.Errorf("Predict(2, 1) = %v, want %v", p, want)
	}
	u, y, s := a.UpdatePosInnovation(12, 4)
	if y != 2 || s != 8 || u.P != 10+0.5*2 || u.PP != 0.5*4 || u.V != 2+(1.0/8)*2 {
		t.Errorf("UpdatePosInnovation = %v, %v, %v", u, y, s)
	}
	if a.UpdatePos(12, 4) != u {
		t.Error("UpdatePos differs from UpdatePosInnovation")
	}
	v, y, s := a.UpdateVelInnovation(5, 1)
	if y != 3 || s != 4 || v.V != 2+0.75*3 || v.VV != 0.25*3 {
		t.Errorf("UpdateVelInnovation = %v, %v, %v", v, y, s)
	}
	if a.UpdateVel(5, 1) != v {
		t.Error("UpdateVel differs from UpdateVelInnovation")
	}
	l := a.List()
	if len(l) != 5 || l[0] != 10.0 || l[4] != 3.0 {
		t.Errorf("List = %v", l)
	}
}

func TestFirstUpdateStep(t *testing.T) {
	p := FilterParams{AccelVar: 1, DefaultCeM: 50, VelSigmaMs: 5, UnknownVelMs: 100}
	z := Measurement{East: 1, North: 2, REast: 9, RNorth: 16}
	m := p.First(z)
	if m.East.VV != 10000 || m.North.PP != 16 || m.East.P != 1 {
		t.Errorf("First without velocity = %v", m)
	}
	z.HasVel, z.VE, z.VN = true, 3, 4
	m = p.First(z)
	if m.East.VV != 25 || m.East.V != 3 || m.North.V != 4 {
		t.Errorf("First with velocity = %v", m)
	}
	// Step without its likelihood is Update after Predict.
	got, g := p.Step(m, 1.5, 2, z)
	want := p.Update(m.Predict(1.5, 2), z)
	if got != want {
		t.Errorf("Step = %v, Update = %v", got, want)
	}
	if math.IsNaN(g) || g == 0 {
		t.Errorf("g = %v", g)
	}
	// Without velocity, two terms only.
	z.HasVel = false
	_, g2 := p.Step(m, 1.5, 2, z)
	e, ye, se := m.Predict(1.5, 2).East.UpdatePosInnovation(z.East, z.REast)
	_, yn, sn := m.Predict(1.5, 2).North.UpdatePosInnovation(z.North, z.RNorth)
	_ = e
	if want := (ye*ye/se + math.Log(se)) + (yn*yn/sn + math.Log(sn)); g2 != want {
		t.Errorf("g = %v, want %v", g2, want)
	}
}

func TestMahalanobis(t *testing.T) {
	pe, pn := Axis{P: 0, PP: 3}, Axis{P: 0, PP: 8}
	if d := Mahalanobis(2, 3, pe, pn, 1, 1); d != 4.0/4+9.0/9 {
		t.Errorf("d2 = %v", d)
	}
}

func TestManeuver(t *testing.T) {
	m := Maneuver{Var: 10, PEnter: 0.1, PLeave: 0.3}
	mu := m.Start()
	if !near(mu[0]+mu[1], 1) || !near(mu[0], 0.75) {
		t.Errorf("Start = %v", mu)
	}
	for _, dt := range []float64{0, 0.5, 1, 10} {
		tr := m.Switching(dt)
		for i := 0; i < 2; i++ {
			if !near(tr[i][0]+tr[i][1], 1) {
				t.Errorf("Switching(%v) row %d = %v", dt, i, tr[i])
			}
		}
	}
	if tr := m.Switching(0); tr[0][1] != 0 || tr[1][0] != 0 {
		t.Errorf("Switching(0) = %v", tr)
	}
	a := Axis{P: 1, V: 2, PP: 3, PV: 4, VV: 5}
	b := Axis{P: 7, V: 8, PP: 9, PV: 10, VV: 11}
	if Blend(1, 0, a, b) != a || Blend(0, 1, a, b) != b {
		t.Error("Blend with weights 1, 0 is not the first axis")
	}
	if c := Blend(0.5, 0.5, a, b); c.P != 4 || c.PP != 0.5*(3+9)+0.5*(9+9) {
		t.Errorf("Blend = %v", c)
	}
}

func TestIMM(t *testing.T) {
	p := FilterParams{AccelVar: 1, DefaultCeM: 50, VelSigmaMs: 5, UnknownVelMs: 100}
	m := Maneuver{Var: 50, PEnter: 0.05, PLeave: 0.2}
	z := Measurement{East: 0, North: 0, REast: 100, RNorth: 100, HasVel: true, VE: 10}
	first := p.First(z)
	s := IMM{Models: [2]Model{first, first}, Mode: m.Start()}
	z2 := z
	z2.East = 10
	step := s.Update(p, m, 1, z2)
	if !near(step.Mode[0]+step.Mode[1], 1) {
		t.Errorf("mode %v", step.Mode)
	}
	if step.Combined != BlendModels(step.Mode[0], step.Mode[1], step.Models) {
		t.Error("Combined is not the blend of the models")
	}
	// A maneuver report raises the maneuver model's probability.
	z3 := z2
	z3.East, z3.VE, z3.VN = 400, -30, 40
	far := step.IMM.Update(p, m, 1, z3)
	if !(far.Mode[1] > step.Mode[1]) {
		t.Errorf("mode after a turn %v, before %v", far.Mode, step.Mode)
	}
	pr := step.IMM.Predict(p, m, 0)
	if pr != step.Combined {
		t.Errorf("Predict(0) = %v, want the combination %v", pr, step.Combined)
	}
	// A transition probability of 0 keeps that model unmixed (c = 0).
	stuck := IMM{Models: [2]Model{first, first}, Mode: [2]float64{1, 0}}
	r := stuck.Update(p, Maneuver{Var: 50, PEnter: 0.5, PLeave: 0.5}, 0, z2)
	if r.Mode[1] != 0 || r.Mode[0] != 1 {
		t.Errorf("mode %v", r.Mode)
	}
}

func num(s string) json.Number { return json.Number(s) }

func TestReportValues(t *testing.T) {
	for _, c := range []struct {
		v     any
		f     float64
		fok   bool
		i     int64
		iok   bool
		isInt bool
	}{
		{num("12"), 12, true, 12, true, true},
		{num("1.5"), 1.5, true, 1, true, false},
		{num("1e3"), 1000, true, 1000, true, false},
		{num("99999999999999999999"), 1e20, true, -9223372036854775808, true, false},
		{num("x"), 0, false, 0, false, false},
		{2.5, 2.5, true, 2, true, false},
		{7, 7, true, 7, true, true},
		{int64(8), 8, true, 8, true, true},
		{"3", 0, false, 0, false, false},
		{true, 0, false, 0, false, false},
		{nil, 0, false, 0, false, false},
	} {
		f, fok := ToFloat(c.v)
		i, iok := ToInt(c.v)
		if f != c.f || fok != c.fok || iok != c.iok || IsInt(c.v) != c.isInt || IsNum(c.v) != c.fok {
			t.Errorf("%#v: ToFloat %v %v, ToInt %v %v, IsInt %v", c.v, f, fok, i, iok, IsInt(c.v))
		}
		if iok && c.iok && c.isInt && i != c.i {
			t.Errorf("%#v: ToInt %v, want %v", c.v, i, c.i)
		}
	}
	if _, ok := ToInt(num("1.5x")); ok {
		t.Error("ToInt of a bad number")
	}
}

func TestValidKeyAndClean(t *testing.T) {
	for _, c := range []struct {
		k  string
		v  any
		ok bool
	}{
		{"uid", "a", true}, {"uid", 1, false}, {"time_ms", num("5"), true}, {"time_ms", num("5.0"), false},
		{"lat", num("5.5"), true}, {"lat", "5", false}, {"type", "a-f-G", true}, {"other", nil, true},
	} {
		if ValidKey(c.k, c.v) != c.ok {
			t.Errorf("ValidKey(%s, %#v) = %v", c.k, c.v, !c.ok)
		}
	}
	r := map[string]any{"track.source_id": "s", "uid": "u", "time_ms": num("1"), "lat": num("1"), "lon": num("2"),
		"ce": num("0"), "hae": "high", "x": nil, "course": num("90"), "stale_ms": num("2.5")}
	if k := MissingKey(r); k != "" {
		t.Errorf("MissingKey = %q", k)
	}
	clean, missing := ReadReport(r)
	if missing != "" {
		t.Fatal(missing)
	}
	for _, k := range []string{"ce", "hae", "x", "stale_ms"} {
		if _, ok := clean[k]; ok {
			t.Errorf("%s kept", k)
		}
	}
	if _, ok := clean["course"]; !ok {
		t.Error("course dropped")
	}
	delete(r, "lat")
	if _, missing := ReadReport(r); missing != "lat" {
		t.Errorf("missing %q", missing)
	}
	if ev := Reject("lat"); ev["reason"] != "missing:lat" || ev["ev"] != "reject" {
		t.Errorf("Reject = %v", ev)
	}
	src, key := EntityKey(map[string]any{"track.source_id": "a", "uid": "b"})
	if src != "a" || key != "a/b" {
		t.Errorf("EntityKey = %q %q", src, key)
	}
	if e, ok := Environment("a-f-G-U"); !ok || e != "G" {
		t.Errorf("Environment = %q %v", e, ok)
	}
	if _, ok := Environment("a-f"); ok {
		t.Error("Environment of two elements")
	}
}

func TestTimeQuality(t *testing.T) {
	parse := func(s string) (float64, error) { return strconv.ParseFloat(s, 64) }
	for _, c := range []struct {
		rest []string
		ok   bool
	}{
		{[]string{"s", "error_ms=5"}, true},
		{[]string{"s", "state=drifting"}, true},
		{[]string{"s", "error_ms=0", "state=free-running"}, true},
		{[]string{"s"}, false},
		{[]string{"error_ms=5", "state=coherent"}, false},
		{[]string{"s", "error_ms"}, false},
		{[]string{"s", "error_ms=-1"}, false},
		{[]string{"s", "error_ms=x"}, false},
		{[]string{"s", "state=late"}, false},
		{[]string{"s", "error_ms=1", "error_ms=2"}, false},
		{[]string{"s", "other=1"}, false},
	} {
		src, d, err := ParseTimeDefault(c.rest, parse)
		if (err == nil) != c.ok {
			t.Errorf("%v: err %v", c.rest, err)
		}
		if err == nil && src != "s" {
			t.Errorf("%v: source %q %v", c.rest, src, d)
		}
	}
	for _, c := range []struct {
		v  any
		ok bool
	}{{num("5"), true}, {num("0"), true}, {num("-1"), false}, {math.Inf(1), false}, {math.NaN(), false}, {"5", false}, {nil, false}} {
		if _, ok := ValidTimeError(c.v); ok != c.ok {
			t.Errorf("ValidTimeError(%v) = %v", c.v, ok)
		}
	}
	if _, ok := ValidTimeState("coherent"); !ok {
		t.Error("coherent")
	}
	if _, ok := ValidTimeState("Coherent"); ok {
		t.Error("Coherent")
	}
	r := CleanTimeQuality(map[string]any{"time_error_ms": num("-3"), "time_state": "lost"})
	if len(r) != 0 {
		t.Errorf("CleanTimeQuality kept %v", r)
	}
	r = CleanTimeQuality(map[string]any{"time_error_ms": num("3"), "time_state": "drifting"})
	if len(r) != 2 {
		t.Errorf("CleanTimeQuality dropped %v", r)
	}
	re, rn, ve, vn := MeasurementVariance(10, 0, 5, 5)
	if re != 100 || rn != 100 || ve != 0 || vn != 0 {
		t.Errorf("MeasurementVariance without time error = %v %v %v %v", re, rn, ve, vn)
	}
	re, rn, ve, vn = MeasurementVariance(10, 200, 5, -10)
	if ve != 1 || vn != 4 || re != 101 || rn != 104 {
		t.Errorf("MeasurementVariance = %v %v %v %v", re, rn, ve, vn)
	}
	pe, pn := AddVariance(Axis{PP: 1}, Axis{PP: 2}, 3, 4)
	if pe.PP != 4 || pn.PP != 6 {
		t.Errorf("AddVariance = %v %v", pe, pn)
	}
}

func TestHelpers(t *testing.T) {
	ks := SortedKeys(map[string]int{"b": 1, "a": 2, "B": 3})
	if len(ks) != 3 || ks[0] != "B" || ks[1] != "a" || ks[2] != "b" {
		t.Errorf("SortedKeys = %v", ks)
	}
	if l := Strings([]string{"x", "y"}); len(l) != 2 || l[1] != "y" {
		t.Errorf("Strings = %v", l)
	}
	if OrNull("") != nil || OrNull("g") != "g" {
		t.Error("OrNull")
	}
}
