// Package io is the engine's input and output: the JSON reader (reports,
// steps files, vectors), the steps runner and events file of the runner
// contract (tools/perf/README.md), the pack.def file and parameter helpers
// every function's pack reader shares, and the structural comparison of
// spec/vector-format.md. It holds no state.
package io

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"goat-correlator/engines/go/model"
)

// DecodeObject parses one JSON object, numbers kept as json.Number.
func DecodeObject(b []byte) (map[string]any, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v map[string]any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	if v == nil {
		return nil, errors.New("not a JSON object")
	}
	return v, nil
}

// ReadObject reads and parses a JSON object file.
func ReadObject(path string) (map[string]any, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	v, err := DecodeObject(b)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return v, nil
}

// Step is one step of a steps file: an ingest (Report not nil) or a tick.
type Step struct {
	Report map[string]any
	Now    int64
}

// ParseSteps reads the `steps` list of a parsed steps file or vector
// (spec/vector-format.md): each step holds `ingest` (a report) or `tick`
// (an integer now_ms); any other key is ignored.
func ParseSteps(doc map[string]any) ([]Step, error) {
	list, ok := doc["steps"].([]any)
	if !ok {
		return nil, errors.New("steps: not a list")
	}
	out := make([]Step, len(list))
	for i, s := range list {
		m, ok := s.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("steps[%d]: not an object", i)
		}
		if r, ok := m["ingest"]; ok {
			rep, ok := r.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("steps[%d].ingest: not an object", i)
			}
			out[i].Report = rep
			continue
		}
		n, ok := m["tick"].(json.Number)
		if !ok {
			return nil, fmt.Errorf("steps[%d]: neither ingest nor tick", i)
		}
		now, err := n.Int64()
		if err != nil {
			return nil, fmt.Errorf("steps[%d].tick: not an integer", i)
		}
		out[i].Now = now
	}
	return out, nil
}

// Result is what one step returned.
type Result struct{ Events, Trace []model.Obj }

// Run calls Ingest or Tick for each step in order, then Snapshot.
func Run(g model.Engine, steps []Step) ([]Result, model.Obj) {
	results := make([]Result, len(steps))
	for i, s := range steps {
		if s.Report != nil {
			results[i].Events, results[i].Trace = g.Ingest(s.Report)
		} else {
			results[i].Events, results[i].Trace = g.Tick(s.Now)
		}
	}
	return results, g.Snapshot()
}

// WriteEvents writes the events file of the runner contract: one line per
// step, {"step": i, "events": [...]} with "trace" when withTrace, then
// {"snapshot": {...}}.
func WriteEvents(path string, results []Result, snap model.Obj, withTrace bool) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	if err := EncodeEvents(w, results, snap, withTrace); err != nil {
		f.Close()
		return err
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// EncodeEvents writes the events file's lines to w.
func EncodeEvents(w interface{ Write([]byte) (int, error) }, results []Result, snap model.Obj, withTrace bool) error {
	enc := json.NewEncoder(w)
	for i, r := range results {
		line := model.Obj{"step": i, "events": nonNil(r.Events)}
		if withTrace {
			line["trace"] = nonNil(r.Trace)
		}
		if err := enc.Encode(line); err != nil {
			return fmt.Errorf("step %d: %w", i, err)
		}
	}
	if err := enc.Encode(model.Obj{"snapshot": snap}); err != nil {
		return fmt.Errorf("snapshot: %w", err)
	}
	return nil
}

// nonNil writes an empty list as [] rather than null.
func nonNil(l []model.Obj) []model.Obj {
	if l == nil {
		return []model.Obj{}
	}
	return l
}

// ReadPackDef reads <dir>/pack.def.
func ReadPackDef(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, "pack.def"))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// Params splits name=value tokens. Every name must be one of required or
// optional and appear at most once, and every required name must be present.
func Params(tokens []string, required, optional []string) (map[string]string, error) {
	out := make(map[string]string, len(tokens))
	for _, tok := range tokens {
		name, value, ok := strings.Cut(tok, "=")
		if !ok || name == "" {
			return nil, fmt.Errorf("parameter without '=': %q", tok)
		}
		if !contains(required, name) && !contains(optional, name) {
			return nil, fmt.Errorf("unknown parameter %q", name)
		}
		if _, seen := out[name]; seen {
			return nil, fmt.Errorf("repeated parameter %q", name)
		}
		out[name] = value
	}
	for _, n := range required {
		if _, ok := out[n]; !ok {
			return nil, fmt.Errorf("missing parameter %q", n)
		}
	}
	return out, nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
