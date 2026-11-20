package proptest

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
)

// Fuzzing of the input parsers: the pack.def reader of every function and
// the JSON reader, with a seeded generator written here (math/rand/v2 PCG,
// fixed seeds), so every run tries the same inputs and the run time is
// bounded: a few thousand inputs, a few seconds. Each input must give a
// value or an error, never a panic; a pack that loads must load the same
// again and run a scenario; reports and steps that parse are run through
// every function. The Fuzz* targets below take the same seeds for
// `go test -fuzz` runs beyond CI.

// corpus is every shipped pack.def and every load vector's pack_def, by
// function.
func corpus(t testing.TB) map[string][]string {
	out := map[string][]string{}
	for _, p := range packs(t) {
		out[p.fn.name] = append(out[p.fn.name], p.text)
	}
	for _, fn := range functions {
		vs, err := io.ReadLoadVectors(filepath.Join(root, "spec", fn.name+"-load-vectors"))
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range vs {
			out[fn.name] = append(out[fn.name], v.PackDef)
		}
	}
	return out
}

// alphabet are the bytes a mutation inserts: the grammar's own and others.
const alphabet = "abcdefghijklmnopqrstuvwxyz_0123456789.-+eE=,;# \t\r\n\x00\x7f\xc3\xa9@/|"

// mutate applies one to four random edits to text: insert, delete or
// replace a byte, duplicate, drop or swap lines, or put a token of another
// text of the corpus in place of one.
func mutate(r *rand.Rand, text string, others []string) string {
	b := []byte(text)
	for n := 1 + r.IntN(4); n > 0; n-- {
		switch r.IntN(7) {
		case 0:
			i := r.IntN(len(b) + 1)
			b = append(b[:i], append([]byte{alphabet[r.IntN(len(alphabet))]}, b[i:]...)...)
		case 1:
			if len(b) > 0 {
				i := r.IntN(len(b))
				b = append(b[:i], b[i+1:]...)
			}
		case 2:
			if len(b) > 0 {
				b[r.IntN(len(b))] = alphabet[r.IntN(len(alphabet))]
			}
		case 3, 4:
			lines := strings.Split(string(b), "\n")
			i, j := r.IntN(len(lines)), r.IntN(len(lines))
			switch r.IntN(3) {
			case 0:
				lines = append(lines[:i], append([]string{lines[j]}, lines[i:]...)...)
			case 1:
				lines = append(lines[:i], lines[i+1:]...)
			default:
				lines[i], lines[j] = lines[j], lines[i]
			}
			b = []byte(strings.Join(lines, "\n"))
		default:
			mine := strings.Fields(string(b))
			theirs := strings.Fields(others[r.IntN(len(others))])
			if len(mine) > 0 && len(theirs) > 0 {
				old, new := mine[r.IntN(len(mine))], theirs[r.IntN(len(theirs))]
				b = []byte(strings.Replace(string(b), old, new, 1))
			}
		}
	}
	return string(b)
}

// parseSafely calls parse and turns a panic into a test failure naming the input.
func parseSafely(t testing.TB, fn function, text string) (mk func() model.Engine, err error) {
	defer func() {
		if p := recover(); p != nil {
			t.Fatalf("%s pack parser panics: %v\ninput: %q", fn.name, p, text)
		}
	}()
	return fn.parse(text)
}

// runSafely runs steps and turns a panic into a test failure naming the
// input. It returns the output printed with fmt (maps in key order), not
// as JSON: an extreme input may give a value JSON cannot hold
// (DISAGREEMENTS.md).
func runSafely(t testing.TB, what string, g model.Engine, steps []io.Step) string {
	defer func() {
		if p := recover(); p != nil {
			t.Fatalf("%s panics: %v", what, p)
		}
	}()
	results, snap := io.Run(g, steps)
	return fmt.Sprint(results, snap)
}

func TestFuzzPackDef(t *testing.T) {
	c := corpus(t)
	r := rand.New(rand.NewPCG(2026, 11))
	steps := scenario(5, 40)
	loaded := 0
	for _, fn := range functions {
		seeds := c[fn.name]
		for i := 0; i < 1500; i++ {
			text := mutate(r, seeds[r.IntN(len(seeds))], seeds)
			mk, err := parseSafely(t, fn, text)
			mk2, err2 := parseSafely(t, fn, text)
			if (err == nil) != (err2 == nil) {
				t.Fatalf("%s: two parses disagree on %q", fn.name, text)
			}
			if err != nil {
				continue
			}
			loaded++
			a := runSafely(t, fmt.Sprintf("%s engine of %q", fn.name, text), mk(), steps)
			if b := runSafely(t, fn.name, mk2(), steps); a != b {
				t.Fatalf("%s: two loads of %q run differently", fn.name, text)
			}
		}
	}
	if loaded == 0 {
		t.Error("no mutated pack loaded: the generator only makes errors")
	}
}

// jsonCorpus is the text of every scenario vector.
func jsonCorpus(t testing.TB) []string {
	files, _ := filepath.Glob(filepath.Join(root, "packs", "*", "vectors", "*.json"))
	sort.Strings(files)
	var out []string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, string(b))
	}
	return out
}

// shrink keeps the steps list of a vector short, so that a mutation lands
// near the reports.
func shrink(text string) string {
	doc, err := io.DecodeObject([]byte(text))
	if err != nil {
		return text
	}
	if steps, ok := doc["steps"].([]any); ok && len(steps) > 12 {
		doc["steps"] = steps[:12]
	}
	delete(doc, "snapshot")
	for _, s := range doc["steps"].([]any) {
		if m, ok := s.(map[string]any); ok {
			delete(m, "expect")
			delete(m, "trace")
		}
	}
	b, _ := json.Marshal(doc)
	return string(b)
}

func TestFuzzJSON(t *testing.T) {
	texts := jsonCorpus(t)
	for i := range texts {
		texts[i] = shrink(texts[i])
	}
	ps := packs(t)
	r := rand.New(rand.NewPCG(1120, 2026))
	parsed := 0
	for i := 0; i < 1500; i++ {
		text := mutate(r, texts[r.IntN(len(texts))], texts)
		doc, err := func() (v map[string]any, err error) {
			defer func() {
				if p := recover(); p != nil {
					t.Fatalf("JSON reader panics: %v\ninput: %q", p, text)
				}
			}()
			return io.DecodeObject([]byte(text))
		}()
		if err != nil {
			continue
		}
		steps, err := io.ParseSteps(doc)
		if err != nil {
			continue
		}
		if !boundedPositions(steps) {
			continue // DISAGREEMENTS.md: an angle of 1e6 degrees or more is not tried
		}
		parsed++
		p := ps[r.IntN(len(ps))]
		runSafely(t, fmt.Sprintf("%s on %q", p.name, text), p.engine(t)(), steps)
	}
	if parsed == 0 {
		t.Error("no mutated steps file parsed")
	}
}

// randomValue is a JSON value of any type.
func randomValue(r *rand.Rand, depth int) any {
	switch r.IntN(9) {
	case 0:
		return nil
	case 1:
		return r.IntN(2) == 0
	case 2:
		return []string{"", "a", "radar", "a-f-G-U", "coherent", "-", "@env", "é"}[r.IntN(8)]
	case 3:
		return json.Number([]string{"0", "-0", "1", "-1", "1e308", "-1e308", "1e-320", "9223372036854775807",
			"9223372036854775808", "-9223372036854775809", "0.5", "1E3", "123456789012345678901234567890"}[r.IntN(13)])
	case 4:
		b, _ := json.Marshal(r.NormFloat64() * 1e4)
		return json.Number(b)
	case 5:
		return json.Number(fmt.Sprint(r.Int64N(1 << 40)))
	case 6:
		if depth > 0 {
			return []any{randomValue(r, depth-1), randomValue(r, depth-1)}
		}
		return []any{}
	case 7:
		if depth > 0 {
			return map[string]any{"k": randomValue(r, depth-1)}
		}
		return map[string]any{}
	}
	return json.Number(fmt.Sprint(r.IntN(200) - 100))
}

// TestFuzzReports: reports whose keys hold values of every type, valid or
// not, through every shipped pack: no input panics an engine.
func TestFuzzReports(t *testing.T) {
	for _, p := range packs(t) {
		runSafely(t, p.name+" on random reports", p.engine(t)(), fuzzSteps(p))
	}
}

// fuzzSteps are the random reports of TestFuzzReports for one pack.
func fuzzSteps(p pack) []io.Step {
	keys := []string{"track.source_id", "uid", "time_ms", "ce", "course", "speed_ms", "hae",
		"stale_ms", "type", "time_error_ms", "time_state", "fuse.group", "received_ms", "quality.marks", "track.simulated"}
	r := rand.New(rand.NewPCG(99, uint64(len(p.name))))
	{
		var steps []io.Step
		for i := 0; i < 300; i++ {
			if r.IntN(8) == 0 {
				steps = append(steps, io.Step{Now: r.Int64N(1<<42) - 1000})
				continue
			}
			rep := map[string]any{"track.source_id": []string{"a", "b"}[r.IntN(2)], "uid": []string{"1", "2"}[r.IntN(2)],
				"time_ms": json.Number(fmt.Sprint(r.IntN(100000))), "lat": json.Number(fmt.Sprint(r.Float64()*0.2 + 50)),
				"lon": json.Number(fmt.Sprint(r.Float64()*0.2 + 8))}
			for n := r.IntN(6); n > 0; n-- {
				rep[keys[r.IntN(len(keys))]] = randomValue(r, 2)
			}
			if r.IntN(10) == 0 { // a position of another type, or out of range but finite and below 1e6
				rep[[]string{"lat", "lon"}[r.IntN(2)]] = []any{nil, "50", true, json.Number("-720.5"), json.Number("999999"), json.Number("1e5")}[r.IntN(6)]
			}
			steps = append(steps, io.Step{Report: rep})
		}
		return steps
	}
}

func FuzzCorrelatePackDef(f *testing.F) { fuzzPackDef(f, functions[0]) }
func FuzzFilterPackDef(f *testing.F)    { fuzzPackDef(f, functions[1]) }
func FuzzFusePackDef(f *testing.F)      { fuzzPackDef(f, functions[2]) }
func FuzzQualityPackDef(f *testing.F)   { fuzzPackDef(f, functions[3]) }

func fuzzPackDef(f *testing.F, fn function) {
	for _, s := range corpus(f)[fn.name] {
		f.Add(s)
	}
	steps := scenario(5, 30)
	f.Fuzz(func(t *testing.T, text string) {
		if mk, err := parseSafely(t, fn, text); err == nil {
			runSafely(t, fn.name, mk(), steps)
		}
	})
}

func FuzzStepsJSON(f *testing.F) {
	for _, s := range jsonCorpus(f)[:20] {
		f.Add([]byte(shrink(s)))
	}
	ps := packs(f)
	f.Fuzz(func(t *testing.T, b []byte) {
		doc, err := io.DecodeObject(b)
		if err != nil {
			return
		}
		steps, err := io.ParseSteps(doc)
		if err != nil || !boundedPositions(steps) {
			return
		}
		for _, p := range ps {
			runSafely(t, p.name, p.engine(t)(), steps)
		}
	})
}

// boundedPositions reports whether every report's lat and lon, when
// numbers, are finite and below 1e6 degrees in magnitude. Wrapping a
// longitude into (-180, 180] adds or subtracts 360 until it is in range
// (correlate.md Frame, filter.md Geometry), which for 1e17 or more never
// ends: the open point in DISAGREEMENTS.md.
func boundedPositions(steps []io.Step) bool {
	for _, s := range steps {
		for _, k := range []string{"lat", "lon"} {
			if f, ok := model.ToFloat(s.Report[k]); ok && !(f > -1e6 && f < 1e6) {
				return false
			}
		}
	}
	return true
}
