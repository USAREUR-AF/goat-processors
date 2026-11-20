package correlate

import (
	"path/filepath"
	"sort"
	"testing"

	"goat-correlator/engines/go/io"
)

// The registration point, proved with a test kind that exists only here:
// "noop" takes no parameter, always passes, and gives value and limit null.
// Registering it is one entry in a Registry; nothing else in the engine
// changes.

const root = "../../.."

func noopRegistry() Registry {
	r := DefaultRegistry()
	r.Tests["noop"] = TestKind{Run: func(Test, Pair) Outcome { return Outcome{Pass: true} }}
	return r
}

// withoutNoop drops the noop records from a trace.
func withoutNoop(trace []any) ([]any, int) {
	out := []any{}
	n := 0
	for _, r := range trace {
		if r.(map[string]any)["test"] == "noop" {
			n++
			continue
		}
		out = append(out, r)
	}
	return out, n
}

// TestNoopUnknownByDefault: the specification's table does not know noop, so
// no shipped pack can name it and the fixture packs do not load without it.
func TestNoopUnknownByDefault(t *testing.T) {
	for _, d := range []string{"noop-confirm", "noop-assign"} {
		if _, err := LoadPack(filepath.Join("testdata", d)); err == nil {
			t.Errorf("%s loads without the noop kind", d)
		}
		if _, err := LoadPackWith(filepath.Join("testdata", d), noopRegistry()); err != nil {
			t.Errorf("%s: %v", d, err)
		}
	}
}

// TestNoopInvisible runs every shipped correlate vector with noop registered:
// a registered kind that no pack names changes nothing.
func TestNoopInvisible(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(root, "packs", "correlate-*", "vectors", "*.json"))
	sort.Strings(files)
	for _, f := range files {
		v, err := io.ReadObject(f)
		if err != nil {
			t.Fatal(err)
		}
		p, err := LoadPackWith(filepath.Join(root, "packs", v["pack"].(string)), noopRegistry())
		if err != nil {
			t.Fatal(err)
		}
		if m := io.CheckVector(New(p), v); m != "" {
			t.Fatalf("%s: %s", f, m)
		}
	}
}

// TestNoopVector runs the vectors of correlate-gnn and correlate-assign on
// the fixture packs, which add noop first on each test line: every event and
// the snapshot are the vector's, and the trace is the vector's once its noop
// records (value and limit null, pass true) are taken out.
func TestNoopVector(t *testing.T) {
	for base, fixture := range map[string]string{"correlate-gnn": "noop-confirm", "correlate-assign": "noop-assign"} {
		p, err := LoadPackWith(filepath.Join("testdata", fixture), noopRegistry())
		if err != nil {
			t.Fatal(err)
		}
		files, _ := filepath.Glob(filepath.Join(root, "packs", base, "vectors", "*.json"))
		sort.Strings(files)
		noops := 0
		for _, f := range files {
			v, err := io.ReadObject(f)
			if err != nil {
				t.Fatal(err)
			}
			steps, err := io.ParseSteps(v)
			if err != nil {
				t.Fatal(err)
			}
			results, snap := io.Run(New(p), steps)
			for i, r := range results {
				step := v["steps"].([]any)[i].(map[string]any)
				if m := io.Mismatch("expect", io.Objs(r.Events), step["expect"]); m != "" {
					t.Fatalf("%s step %d: %s", f, i, m)
				}
				tr, n := withoutNoop(io.Objs(r.Trace))
				noops += n
				if m := io.Mismatch("trace", tr, step["trace"]); m != "" {
					t.Fatalf("%s step %d: %s", f, i, m)
				}
				for j, rec := range r.Trace {
					if rec["test"] == "noop" && (rec["value"] != nil || rec["limit"] != nil || rec["pass"] != true) {
						t.Fatalf("%s step %d: noop record %d is %v", f, i, j, rec)
					}
				}
			}
			if m := io.Mismatch("snapshot", snap, v["snapshot"]); m != "" {
				t.Fatalf("%s: %s", f, m)
			}
		}
		if noops == 0 {
			t.Errorf("%s: no noop record was given", fixture)
		}
	}
}
