package quality

import (
	"path/filepath"
	"testing"
)

// The measures table is the registration point of a quality measure: one
// row in a Registry, nothing else changes. "always_one" exists only here.
func oneRegistry() Registry {
	r := DefaultRegistry()
	r.Measures = append(r.Measures, Measure{Name: "always_one", Entity: func(*Window) any { return int64(1) }, Source: Sum})
	return r
}

func TestMeasureRegistration(t *testing.T) {
	dir := filepath.Join("testdata", "measure")
	if _, err := LoadPack(dir); err == nil {
		t.Fatal("the fixture loads without always_one registered")
	}
	p, err := LoadPackWith(dir, oneRegistry())
	if err != nil {
		t.Fatal(err)
	}
	g := New(p)
	report := func(src, uid string, t int64) map[string]any {
		return map[string]any{"track.source_id": src, "uid": uid, "time_ms": t, "lat": 50.0, "lon": 8.0}
	}
	g.Ingest(report("r", "1", 1000))
	g.Ingest(report("r", "2", 1000))
	events, trace := g.Tick(2000)
	var starts []string
	for _, ev := range events {
		switch ev["ev"] {
		case "quality":
			m := ev["measures"].(Obj)
			want := int64(1)
			if ev["scope"] == "source" {
				want = 2 // Sum over the two entities
			}
			if m["always_one"] != want {
				t.Errorf("%v %v: always_one = %v, want %d", ev["scope"], ev["subject"], m["always_one"], want)
			}
		case "action-start":
			starts = append(starts, ev["rule"].(string)+" "+ev["subject"].(string))
		}
	}
	want := []string{"one r/1", "one r/2", "one-src r"}
	if len(starts) != len(want) {
		t.Fatalf("action-start events %v, want %v", starts, want)
	}
	for i := range want {
		if starts[i] != want[i] {
			t.Fatalf("action-start events %v, want %v", starts, want)
		}
	}
	if len(trace) != 3 {
		t.Errorf("%d rule records, want 3", len(trace))
	}
	// Each pass event of a later report carries the mark of rule one.
	events, _ = g.Ingest(report("r", "1", 3000))
	pass := events[len(events)-1]
	if marks := pass["report"].(map[string]any)["quality.marks"].([]any); len(marks) != 1 || marks[0] != "one" {
		t.Errorf("marks %v", marks)
	}
}

// TestEntityRuleNeedsEntityMeasure: "entities" is a source measure only.
func TestEntityRuleNeedsEntityMeasure(t *testing.T) {
	base := "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\n"
	if _, err := ParsePack(base + "rule r scope=entity measure=entities op=> limit=1 for=1 clear=1 action=alert\n"); err == nil {
		t.Error("an entity rule on entities loads")
	}
	if _, err := ParsePack(base + "rule r scope=source measure=entities op=> limit=1 for=1 clear=1 action=alert\n"); err != nil {
		t.Error(err)
	}
}
