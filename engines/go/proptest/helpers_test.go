// Package proptest holds the engine's property tests and fuzzing: they run
// every function through its public entry point (model.Engine). They live
// apart from the vector tests so that the perf harness, which times the
// vector test binaries, does not time them.
package proptest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"math/rand/v2"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"goat-correlator/engines/go/correlate"
	"goat-correlator/engines/go/filter"
	"goat-correlator/engines/go/fuse"
	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/quality"
)

const root = "../../.."

// function is one function's entry points.
type function struct {
	name  string
	parse func(text string) (func() model.Engine, error) // a new engine for the pack, per call
}

var functions = []function{
	{"correlate", func(text string) (func() model.Engine, error) {
		p, err := correlate.ParsePack(text)
		return func() model.Engine { return correlate.New(p) }, err
	}},
	{"filter", func(text string) (func() model.Engine, error) {
		p, err := filter.ParsePack(text)
		return func() model.Engine { return filter.New(p) }, err
	}},
	{"fuse", func(text string) (func() model.Engine, error) {
		p, err := fuse.ParsePack(text)
		return func() model.Engine { return fuse.New(p) }, err
	}},
	{"quality", func(text string) (func() model.Engine, error) {
		p, err := quality.ParsePack(text)
		return func() model.Engine { return quality.New(p) }, err
	}},
}

// pack is one shipped pack.
type pack struct {
	fn      function
	name    string
	text    string
	vectors []string
}

func packs(t testing.TB) []pack {
	t.Helper()
	var out []pack
	for _, fn := range functions {
		dirs, _ := filepath.Glob(filepath.Join(root, "packs", fn.name+"-*"))
		sort.Strings(dirs)
		for _, d := range dirs {
			text, err := io.ReadPackDef(d)
			if err != nil {
				t.Fatal(err)
			}
			vs, _ := filepath.Glob(filepath.Join(d, "vectors", "*.json"))
			sort.Strings(vs)
			out = append(out, pack{fn, filepath.Base(d), text, vs})
		}
	}
	if len(out) == 0 {
		t.Fatal("no packs")
	}
	return out
}

func (p pack) engine(t testing.TB) func() model.Engine {
	t.Helper()
	mk, err := p.fn.parse(p.text)
	if err != nil {
		t.Fatalf("%s: %v", p.name, err)
	}
	return mk
}

func readSteps(t testing.TB, path string) []io.Step {
	t.Helper()
	v, err := io.ReadObject(path)
	if err != nil {
		t.Fatal(err)
	}
	steps, err := io.ParseSteps(v)
	if err != nil {
		t.Fatal(err)
	}
	return steps
}

// output is the events file of a run, with trace: what the golden files hold.
func output(t testing.TB, results []io.Result, snap model.Obj) []byte {
	t.Helper()
	var b bytes.Buffer
	if err := io.EncodeEvents(&b, results, snap, true); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func runBytes(t testing.TB, g model.Engine, steps []io.Step) []byte {
	t.Helper()
	results, snap := io.Run(g, steps)
	return output(t, results, snap)
}

// firstDiff names the first differing line of two outputs.
func firstDiff(a, b []byte) string {
	la, lb := strings.Split(string(a), "\n"), strings.Split(string(b), "\n")
	for i := 0; i < len(la) && i < len(lb); i++ {
		if la[i] != lb[i] {
			return fmt.Sprintf("line %d:\n  %.300s\n  %.300s", i, la[i], lb[i])
		}
	}
	return fmt.Sprintf("%d lines against %d", len(la), len(lb))
}

// scenario is a seeded random input: reports of several sources and
// entities around one point, with every optional key sometimes present,
// sometimes of a wrong type, and a tick every second.
func scenario(seed uint64, n int) []io.Step {
	r := rand.New(rand.NewPCG(seed, 0x9e3779b97f4a7c15))
	num := func(f float64) json.Number { b, _ := json.Marshal(f); return json.Number(b) }
	sources := []string{"radar", "beacon", "passive"}
	type obj struct{ lat, lon, course, speed float64 }
	objs := make([]obj, 4)
	for i := range objs {
		objs[i] = obj{50 + r.Float64()*0.05, 8 + r.Float64()*0.05, r.Float64() * 360, 5 + r.Float64()*40}
	}
	var steps []io.Step
	t := int64(1000)
	for len(steps) < n {
		if r.IntN(6) == 0 {
			steps = append(steps, io.Step{Now: t})
			t += 1000
			continue
		}
		o := r.IntN(len(objs))
		src := sources[r.IntN(len(sources))]
		dt := float64(t) / 1000
		lat := objs[o].lat + dt*objs[o].speed*0.000009*cosd(objs[o].course) + r.NormFloat64()*0.0002
		lon := objs[o].lon + dt*objs[o].speed*0.000014*sind(objs[o].course) + r.NormFloat64()*0.0002
		rep := map[string]any{"track.source_id": src, "uid": fmt.Sprintf("t%d", o), "lat": num(lat), "lon": num(lon),
			"time_ms": json.Number(fmt.Sprint(t - int64(r.IntN(3))*int64(r.IntN(900))))}
		if r.IntN(4) > 0 {
			rep["course"], rep["speed_ms"] = num(objs[o].course+r.NormFloat64()*5), num(objs[o].speed+r.NormFloat64())
		}
		if r.IntN(3) > 0 {
			rep["ce"] = num(5 + r.Float64()*60)
		}
		if r.IntN(3) == 0 {
			rep["hae"] = num(1000 + r.Float64()*50)
		}
		if r.IntN(4) == 0 {
			rep["time_error_ms"] = num(r.Float64() * 300)
		}
		if r.IntN(5) == 0 {
			rep["time_state"] = []string{"coherent", "drifting", "free-running", "lost"}[r.IntN(4)]
		}
		if r.IntN(3) > 0 {
			rep["fuse.group"] = fmt.Sprintf("g%d", o)
		}
		if r.IntN(3) == 0 {
			rep["received_ms"] = json.Number(fmt.Sprint(t + int64(r.IntN(2000))))
		}
		if r.IntN(4) == 0 {
			rep["type"] = []string{"a-f-A", "a-h-G-U", "a-f-G", "x"}[r.IntN(4)]
		}
		if r.IntN(25) == 0 {
			rep["ce"] = "wide" // a wrong type is absent
		}
		if r.IntN(40) == 0 {
			delete(rep, "lat") // a reject
		}
		steps = append(steps, io.Step{Report: rep})
	}
	return steps
}

func cosd(d float64) float64 { return math.Cos(d * math.Pi / 180) }
func sind(d float64) float64 { return math.Sin(d * math.Pi / 180) }
