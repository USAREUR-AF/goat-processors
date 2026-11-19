package quality

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"testing"

	correlator "goat-correlator/engines/go"
)

const root = "../../.."

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v map[string]any
	if err := d.Decode(&v); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return v
}

// mismatch returns the path of the first difference, or "" when got equals
// want (spec/vector-format.md: What the engine checks).
func mismatch(path string, got, want any) string {
	if wn, ok := correlator.ToFloat(want); ok {
		gn, ok := correlator.ToFloat(got)
		if !ok || math.Abs(gn-wn) > 1e-6*math.Max(1, math.Abs(wn)) {
			return fmt.Sprintf("%s: got %#v, want %v", path, got, want)
		}
		return ""
	}
	switch w := want.(type) {
	case nil, string, bool:
		if got != want {
			return fmt.Sprintf("%s: got %#v, want %#v", path, got, want)
		}
		return ""
	case []any:
		g, ok := got.([]any)
		if !ok || len(g) != len(w) {
			return fmt.Sprintf("%s: got %v, want %v", path, got, want)
		}
		for i := range w {
			if m := mismatch(fmt.Sprintf("%s[%d]", path, i), g[i], w[i]); m != "" {
				return m
			}
		}
		return ""
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return fmt.Sprintf("%s: got %v, want an object", path, got)
		}
		keys := map[string]bool{}
		for k := range w {
			keys[k] = true
		}
		for k := range g {
			keys[k] = true
		}
		for _, k := range sortedKeys(keys) {
			gv, gok := g[k]
			wv, wok := w[k]
			if gok != wok {
				return fmt.Sprintf("%s.%s: present in got=%v, in want=%v", path, k, gok, wok)
			}
			if m := mismatch(path+"."+k, gv, wv); m != "" {
				return m
			}
		}
		return ""
	}
	return fmt.Sprintf("%s: unexpected want type %T", path, want)
}

func objs(list []Obj) []any {
	out := make([]any, len(list))
	for i, o := range list {
		out[i] = o
	}
	return out
}

// TestScenarioVectors runs packs/quality-*/vectors/*.json: every step's events
// and trace, then the final snapshot.
func TestScenarioVectors(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(root, "packs", "quality-*", "vectors", "*.json"))
	sort.Strings(files)
	if len(files) == 0 {
		t.Fatal("no quality scenario vectors found")
	}
	for _, f := range files {
		v := readJSON(t, f)
		t.Run(fmt.Sprint(v["pack"], "/", v["name"]), func(t *testing.T) {
			pack, err := LoadPack(filepath.Join(root, "packs", v["pack"].(string)))
			if err != nil {
				t.Fatal(err)
			}
			g := New(pack)
			for i, s := range v["steps"].([]any) {
				step := s.(map[string]any)
				var events, trace []Obj
				if r, ok := step["ingest"]; ok {
					events, trace = g.Ingest(r.(map[string]any))
				} else {
					now, _ := correlator.ToInt(step["tick"])
					events, trace = g.Tick(now)
				}
				p := fmt.Sprintf("steps[%d]", i)
				if m := mismatch(p+".expect", objs(events), step["expect"]); m != "" {
					t.Fatal(m)
				}
				if m := mismatch(p+".trace", objs(trace), step["trace"]); m != "" {
					t.Fatal(m)
				}
			}
			if m := mismatch("snapshot", g.Snapshot(), v["snapshot"]); m != "" {
				t.Fatal(m)
			}
		})
	}
}

// TestLoadVectors runs spec/quality-load-vectors/*.json.
func TestLoadVectors(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(root, "spec", "quality-load-vectors", "*.json"))
	sort.Strings(files)
	if len(files) == 0 {
		t.Fatal("no quality load vectors found")
	}
	for _, f := range files {
		v := readJSON(t, f)
		t.Run(v["name"].(string), func(t *testing.T) {
			_, err := ParsePack(v["pack_def"].(string))
			if want := v["expect_error"].(bool); (err != nil) != want {
				t.Fatalf("expect_error=%v, got error %v", want, err)
			}
		})
	}
}

// TestShippedPacksLoad checks every packs/quality-*/pack.def loads.
func TestShippedPacksLoad(t *testing.T) {
	dirs, _ := filepath.Glob(filepath.Join(root, "packs", "quality-*", "pack.def"))
	if len(dirs) == 0 {
		t.Fatal("no quality packs found")
	}
	for _, d := range dirs {
		if _, err := LoadPack(filepath.Dir(d)); err != nil {
			t.Errorf("%s: %v", d, err)
		}
	}
}
