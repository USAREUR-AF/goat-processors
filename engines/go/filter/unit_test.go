package filter

import (
	"encoding/json"
	"math"
	"testing"
)

func TestGeometry(t *testing.T) {
	if d := distance(0, 0, 0, 1); math.Abs(d-111195.08) > 0.1 {
		t.Errorf("one degree of longitude at the equator = %v", d)
	}
	if d := distance(10, 179.9, 10, -179.9); d > 30000 {
		t.Errorf("across the antimeridian = %v", d)
	}
	sq := []Vertex{{0, 0}, {0, 10}, {10, 10}, {10, 0}}
	for _, c := range []struct {
		lat, lon float64
		want     string
	}{{5, 5, inside}, {0, 5, boundary}, {10, 10, boundary}, {11, 5, outside}, {5, -1, outside}} {
		if got := polygonTest(sq, c.lat, c.lon); got != c.want {
			t.Errorf("polygonTest(%v, %v) = %v", c.lat, c.lon, got)
		}
	}
	c, s := 90.0, 10.0
	lat, lon := predict(&State{TimeMs: 0, Lat: 0, Lon: 0, Course: &c, SpeedMs: &s}, 1000)
	if math.Abs(lat) > 1e-15 || !(lon > 0) {
		t.Errorf("predict east: %v %v", lat, lon)
	}
	if lat, lon := predict(&State{Lat: 1, Lon: 2}, 5000); lat != 1 || lon != 2 {
		t.Errorf("predict without velocity: %v %v", lat, lon)
	}
}

func TestConditionHelpers(t *testing.T) {
	if r := (result{truth: unknown}); r.passes(true) || r.passes(false) {
		t.Error("unknown passes")
	}
	if !(result{truth: isTrue}).passes(false) || (result{truth: isTrue}).passes(true) {
		t.Error("not")
	}
	for _, c := range []struct {
		v    any
		text string
		eq   bool
	}{
		{"a", "a", true}, {true, "true", true}, {false, "false", true}, {true, "1", false},
		{json.Number("2.50"), "2.5", true}, {json.Number("2"), "x", false}, {[]any{}, "a", false},
	} {
		if keyEqual(c.v, c.text) != c.eq {
			t.Errorf("keyEqual(%#v, %q)", c.v, c.text)
		}
	}
	r := &report{values: map[string]any{"type": "b-x"}}
	if _, ok := r.affiliation(); ok {
		t.Error("affiliation of a type not starting with a")
	}
	r.values["type"] = "a"
	if _, ok := r.affiliation(); ok {
		t.Error("affiliation of a one-element type")
	}
	min := 5.0
	if res := rangeOf(true, Condition{Min: &min}); res.truth != unknown {
		t.Error("a boolean in a range")
	}
}

func TestPackErrors(t *testing.T) {
	base := "pack p\nversion 1\ndefault keep\nforget_ms 10\n"
	if _, err := ParsePack(base); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		base + "rule r keep\nwhen circle lat=91 lon=0 radius_m=1\n",
		base + "rule r keep\nwhen circle lat=0 lon=181 radius_m=1\n",
		base + "rule r keep\nwhen circle lat=0 lon=0 radius_m=-1\n",
		base + "rule r keep\nwhen polygon vertices=0,0;1,1\n",
		base + "rule r keep\nwhen polygon vertices=0,0;1,1;2\n",
		base + "rule r keep\nwhen polygon vertices=0,0;1,1;x,2\n",
		base + "rule r keep\nwhen polygon vertices=0,0;1,1;2,x\n",
		base + "rule r keep\nwhen speed min=5 max=1\n",
		base + "rule r keep\nwhen interval min_ms=0\n",
		base + "rule r keep\nwhen key name= eq=1\n",
		base + "rule r keep\nwhen env in=a,,b\n",
		base + "rule r keep\nwhen not\n",
		base + "rule r keep\nwhen near reference=s/1 radius_m=1 max_age_ms=1.5\n",
		base + "rule r keep\nwhen has name=x name=y\n",
		base + "rule r keep\nwhen has name\n",
		"pack p\nversion 1\ndefault keep\nforget_ms 99999999999999999999\n",
		"pack p\nversion 1\ndefault keep\nforget_ms 0\n",
		"pack p\nversion 1\ndefault maybe\nforget_ms 1\n",
		base + "rule r maybe\nwhen has name=x\n",
	} {
		if _, err := ParsePack(bad); err == nil {
			t.Errorf("loads:\n%s", bad)
		}
	}
	if _, err := Load("testdata/none"); err == nil {
		t.Error("a missing pack loads")
	}
}
