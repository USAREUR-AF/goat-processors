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

// writer is what the counters and diagnostics are written to.
type writer interface{ Write([]byte) (int, error) }

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

// run is the runner on its arguments; it returns the exit status.
func run(args []string, stdout, stderr writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "runner: "+format+"\n", a...)
		return 2
	}
	fs := flag.NewFlagSet("runner", flag.ContinueOnError)
	fs.SetOutput(stderr)
	function := fs.String("function", "", "correlate, filter, fuse or quality")
	packDir := fs.String("pack", "", "pack directory")
	stepsPath := fs.String("steps", "", "steps file")
	eventsPath := fs.String("events", "", "events file to write")
	withTrace := fs.Bool("trace", false, "include each step's trace")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	load, ok := functions[*function]
	if !ok {
		return fail("unknown function %q", *function)
	}
	if *packDir == "" || *stepsPath == "" {
		return fail("--pack and --steps are required")
	}

	t0 := time.Now()
	doc, err := io.ReadObject(*stepsPath)
	if err != nil {
		return fail("steps file: %v", err)
	}
	steps, err := io.ParseSteps(doc)
	if err != nil {
		return fail("steps file: %v", err)
	}
	t1 := time.Now()
	g, err := load(*packDir)
	if err != nil {
		return fail("pack: %v", err)
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
			return fail("events file: %v", err)
		}
	}
	counters, _ := json.Marshal(model.Obj{
		"engine": "go", "function": *function, "pack": filepath.Base(filepath.Clean(*packDir)),
		"steps": len(steps), "ingest": nIngest, "tick": len(steps) - nIngest,
		"events": nEvents, "trace_records": nTrace,
		"parse_ns": t1.Sub(t0).Nanoseconds(), "load_ns": t2.Sub(t1).Nanoseconds(), "run_ns": t3.Sub(t2).Nanoseconds(),
	})
	fmt.Fprintln(stdout, string(counters))
	return 0
}
