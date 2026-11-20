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
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"goat-correlator/engines/go/correlate"
	"goat-correlator/engines/go/filter"
	"goat-correlator/engines/go/fuse"
	"goat-correlator/engines/go/io"
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/quality"
)

// functions is the engine's function table: each function's Load, the one
// entry-point shape (model.Engine).
var functions = map[string]func(dir string) (model.Engine, error){
	"correlate": func(dir string) (model.Engine, error) { return correlate.Load(dir) },
	"filter":    func(dir string) (model.Engine, error) { return filter.Load(dir) },
	"fuse":      func(dir string) (model.Engine, error) { return fuse.Load(dir) },
	"quality":   func(dir string) (model.Engine, error) { return quality.Load(dir) },
}

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

	load, ok := functions[*function]
	if !ok {
		fail("unknown function %q", *function)
	}
	if *packDir == "" || *stepsPath == "" {
		fail("--pack and --steps are required")
	}

	t0 := time.Now()
	doc, err := io.ReadObject(*stepsPath)
	if err != nil {
		fail("steps file: %v", err)
	}
	steps, err := io.ParseSteps(doc)
	if err != nil {
		fail("steps file: %v", err)
	}
	t1 := time.Now()
	g, err := load(*packDir)
	if err != nil {
		fail("pack: %v", err)
	}
	t2 := time.Now()
	results, snap := io.Run(g, steps)
	t3 := time.Now()

	var nIngest, nEvents, nTrace int
	for i, s := range steps {
		if s.Report != nil {
			nIngest++
		}
		nEvents += len(results[i].Events)
		nTrace += len(results[i].Trace)
	}
	if *eventsPath != "" {
		if err := io.WriteEvents(*eventsPath, results, snap, *withTrace); err != nil {
			fail("events file: %v", err)
		}
	}
	counters, _ := json.Marshal(model.Obj{
		"engine": "go", "function": *function, "pack": filepath.Base(filepath.Clean(*packDir)),
		"steps": len(steps), "ingest": nIngest, "tick": len(steps) - nIngest,
		"events": nEvents, "trace_records": nTrace,
		"parse_ns": t1.Sub(t0).Nanoseconds(), "load_ns": t2.Sub(t1).Nanoseconds(), "run_ns": t3.Sub(t2).Nanoseconds(),
	})
	fmt.Println(string(counters))
}
