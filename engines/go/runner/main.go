// Command runner is the Go engine's command-line runner: the contract of
// tools/perf/README.md, "Runner contract".
//
//	run --function <correlate|filter|fuse|quality> --pack <dir> --steps <file>
//	    [--events <file>] [--trace]
//
// It parses the steps file, loads the pack, creates the engine, calls Ingest
// or Tick once per step in order and Snapshot after the last, and prints one
// line of counters on standard output.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	correlator "goat-correlator/engines/go"
	"goat-correlator/engines/go/filter"
	"goat-correlator/engines/go/fuse"
	"goat-correlator/engines/go/quality"
)

type obj = map[string]any

// engine is the shape every function's engine has.
type engine interface {
	Ingest(report map[string]any) (events, trace []obj)
	Tick(now int64) (events, trace []obj)
	Snapshot() obj
}

// loaders maps a function name to its pack loader and engine constructor.
var loaders = map[string]func(dir string) (engine, error){
	"correlate": func(dir string) (engine, error) {
		p, err := correlator.LoadPack(dir)
		if err != nil {
			return nil, err
		}
		return correlator.New(p), nil
	},
	"filter": func(dir string) (engine, error) {
		p, err := filter.LoadPack(dir)
		if err != nil {
			return nil, err
		}
		return filter.New(p), nil
	},
	"fuse": func(dir string) (engine, error) {
		p, err := fuse.LoadPack(dir)
		if err != nil {
			return nil, err
		}
		return fuse.New(p), nil
	},
	"quality": func(dir string) (engine, error) {
		p, err := quality.LoadPack(dir)
		if err != nil {
			return nil, err
		}
		return quality.New(p), nil
	},
}

// step is one ingest or tick of the steps file.
type step struct {
	report map[string]any // nil for a tick
	now    int64
}

func parseSteps(path string) ([]step, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var doc map[string]any
	if err := d.Decode(&doc); err != nil {
		return nil, err
	}
	list, ok := doc["steps"].([]any)
	if !ok {
		return nil, errors.New("steps: not a list")
	}
	out := make([]step, len(list))
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
			out[i].report = rep
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
		out[i].now = now
	}
	return out, nil
}

type result struct{ events, trace []obj }

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "runner: "+format+"\n", a...)
	os.Exit(2)
}

func main() {
	function := flag.String("function", "", "correlate, filter, fuse or quality")
	packDir := flag.String("pack", "", "pack directory")
	stepsPath := flag.String("steps", "", "steps file")
	eventsPath := flag.String("events", "", "events file to write")
	withTrace := flag.Bool("trace", false, "include each step's trace")
	flag.Parse()

	load, ok := loaders[*function]
	if !ok {
		fail("unknown function %q", *function)
	}
	if *packDir == "" || *stepsPath == "" {
		fail("--pack and --steps are required")
	}

	t0 := time.Now()
	steps, err := parseSteps(*stepsPath)
	if err != nil {
		fail("steps file: %v", err)
	}
	t1 := time.Now()
	g, err := load(*packDir)
	if err != nil {
		fail("pack: %v", err)
	}
	t2 := time.Now()
	results := make([]result, len(steps))
	for i, s := range steps {
		if s.report != nil {
			results[i].events, results[i].trace = g.Ingest(s.report)
		} else {
			results[i].events, results[i].trace = g.Tick(s.now)
		}
	}
	snap := g.Snapshot()
	t3 := time.Now()

	var nIngest, nEvents, nTrace int
	for i, s := range steps {
		if s.report != nil {
			nIngest++
		}
		nEvents += len(results[i].events)
		nTrace += len(results[i].trace)
	}
	if *eventsPath != "" {
		if err := writeEvents(*eventsPath, results, snap, *withTrace); err != nil {
			fail("events file: %v", err)
		}
	}
	counters, _ := json.Marshal(obj{
		"engine": "go", "function": *function, "pack": filepath.Base(filepath.Clean(*packDir)),
		"steps": len(steps), "ingest": nIngest, "tick": len(steps) - nIngest,
		"events": nEvents, "trace_records": nTrace,
		"parse_ns": t1.Sub(t0).Nanoseconds(), "load_ns": t2.Sub(t1).Nanoseconds(), "run_ns": t3.Sub(t2).Nanoseconds(),
	})
	fmt.Println(string(counters))
}

func writeEvents(path string, results []result, snap obj, withTrace bool) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	enc := json.NewEncoder(w)
	for i, r := range results {
		line := obj{"step": i, "events": nonNil(r.events)}
		if withTrace {
			line["trace"] = nonNil(r.trace)
		}
		if err := enc.Encode(line); err != nil {
			f.Close()
			return fmt.Errorf("step %d: %w", i, err)
		}
	}
	if err := enc.Encode(obj{"snapshot": snap}); err != nil {
		f.Close()
		return fmt.Errorf("snapshot: %w", err)
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// nonNil writes an empty list as [] rather than null.
func nonNil(l []obj) []obj {
	if l == nil {
		return []obj{}
	}
	return l
}
