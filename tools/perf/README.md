# tools/perf

Status: Written. Measures each engine's speed and memory, per function
(correlate, filter, fuse, quality). Python, standard library only; run every
command with `python3 -I`. The results page is
[docs/performance.md](../../docs/performance.md); the harness writes it, never
a person.

| File | What it holds |
|---|---|
| `perf.py` | the harness: `generate`, `baseline`, `report`, `smoke` |
| `scenario.py` | the large generated input: seeded, deterministic |
| `run_python.py` | the runner contract for the Python engine (below) |
| `test_perf.py` | the harness's own tests (CI) |

## Commands

| Command | Does |
|---|---|
| `perf.py generate --out DIR [--size large\|smoke]` | writes the generated steps file of every function |
| `perf.py baseline [--repeats N] [--large-repeats N] [--engines a,b] [--work DIR]` | builds and times every engine; writes `docs/figures/perf/results.json` and `docs/performance.md`. Needs every toolchain of `.github/workflows/conformance.yml`. About 15 minutes |
| `perf.py report [--check]` | rewrites `docs/performance.md` from `results.json`; `--check` exits 1 if the committed page differs |
| `perf.py smoke` | CI's short run: the Python runner on the smoke scenario for every large-scenario pack, and one vector command. It checks that they run and count, not how fast |

CI runs `test_perf.py`, `perf.py smoke` and `perf.py report --check`
(`.github/workflows/perf.yml`). Timings depend on the machine, so CI never
checks a number.

## Method

**What is timed.** The committed tree (`git archive HEAD`) is copied to a
work directory, so uncommitted edits are never measured. Each engine is
built there first; the build is never timed. Then each timed command runs
`--repeats` times (default 10) on the conformance vectors and
`--large-repeats` times (default 3) on the large scenario. Each cell of the
page is the median, with the range from the slowest to the fastest run.
Runs are sequential; nothing else of the harness runs meanwhile.

**Wall time** is measured by the harness around the whole command
(`time.perf_counter`). **Peak memory** is the command's maximum resident set
as GNU time reports it (`/usr/bin/time -f %M`). The harness does not read it
from its own `wait4`: on Linux a child forked from the harness can report the
harness's resident set, which would hide an engine smaller than that.

**Reports per second** = the reports (ingest steps) of the input divided by
the time. On the vector commands the time also covers everything the command
does besides the engine; on a runner it covers the engine calls only.

**Machine and toolchains** are read by the harness and printed at the top of
the page: CPU, cores, memory, OS, and each compiler or VM version.

### What each engine's number covers today

Until every engine has a runner, the six compiled or VM engines are timed
through what exists: their vector test commands, one per function, built
with the optimized profile the project already defines.

| Engine | Build (not timed) | Timed, per function |
|---|---|---|
| python | none | `python3 -m unittest test_vectors` (or `test_filter_vectors`, `test_fuse_vectors`, `test_quality_vectors`) in `engines/python/tests`, `PYTHONPATH=src` |
| rust | `cargo test --release --no-run` | the test binary `vectors`, `filter_vectors`, `fuse_vectors` or `quality_vectors`, with `--test-threads=1` |
| go | `go test -c` per package | the package's test binary in its directory (`.`, `filter`, `fuse`, `quality`); every test of the package |
| java | `javac --release 17` | `java -cp build correlator.VectorTest <root>` (`filter.VectorTest`, `fuse.FuseVectorTest`, `quality.VectorTest`) |
| cpp | `cmake -S engines/cpp -B ...` (Release, the project default), `cmake --build` | `run_vectors <root>` (`run_filter_vectors`, `run_fuse_vectors`, `run_quality_vectors`) |
| erlang | `engines/erlang/build.sh` | `erl -noshell -pa ebin -run correlator_vectors main <root>` (`filter_vectors`, `fuse_vectors`, `quality_vectors`) |
| zig | `zig test -O ReleaseFast --test-no-exec` per test file, with the same `paths` module `build.zig` makes | the test binary of `vectors_test.zig`, `filter_vectors_test.zig`, `fuse_vectors_test.zig` or `quality_vectors_test.zig` |

Each covers process or VM start, reading and parsing every vector file of
the function (scenario and load vectors), the engine, and comparing every
step with the expected events and trace. These numbers are comparable
between runs of one engine; between engines they also compare JSON parsers
and start-up cost.

## The large scenario

`scenario.py` builds one seeded scenario with the bench's scenario model
(`tools/bench/scenarios.py`). The baseline size, `large`, is 12 objects for
600 s seen by a radar, two beacons (one with a clock 200 ms ahead) and a
passive sensor (understated error, clock drifting 10 ms per minute), with
false tracks, a track-number swap and a drop: 18,571 reports and 600 ticks.
The same reports go to every function; fuse's also carry `fuse.group` (the
truth object). `smoke` is 3 objects for 60 s.

| Function | Packs |
|---|---|
| correlate | `correlate-gnn-imm`, `correlate-assign-time` |
| filter | `filter-thin` |
| fuse | `fuse-independent` |
| quality | `quality-time` |

The size is set by `correlate-assign-time`, whose cost grows about with the
cube of the number of objects in this scenario (Python: 8 objects 1,304
reports per second, 12 objects 495, 16 objects 245).

**Through the vector commands.** The harness writes the scenario as a vector
of each pack, with the expected events, trace and snapshot from the Python
engine (as `tools/make-vectors.py` does), into a copy of the tree that holds
no other scenario vectors, builds every engine there and times the same
commands. The number then covers parsing that vector and comparing every
step. A cell that fails is an engine that cannot run the large scenario
today through its vector command, or whose output differs from Python's on
it.

## Runner contract

Every engine gets one command-line runner in the refactor (its IO module).
The harness times it with no change to the harness, and from then on the
"engine calls only" table covers all seven engines.

**Files.** In `engines/<lang>/runner/`:

| File | Contract |
|---|---|
| `build` | executable; no arguments; builds the runner with the engine's optimized profile; exit 0 on success. Optional when nothing needs building |
| `run` | executable; runs the built runner with the arguments below. It must not build |

**Invocation.**

```
run --function <correlate|filter|fuse|quality> --pack <pack directory> --steps <file>
    [--events <file>] [--trace]
```

| Argument | Meaning |
|---|---|
| `--function` | which engine function to run |
| `--pack` | a pack directory (`pack.def` inside), loaded as that function's `load_pack` |
| `--steps` | a JSON object whose `steps` is a list of steps in the format of `spec/vector-format.md`: each holds `ingest` (a report) or `tick` (an integer `now_ms`). Any other key, in the object or in a step (`expect`, `trace`, `name`), is ignored. A scenario vector is therefore a valid steps file |
| `--events` | write the output here (below). Without it, write nothing but the counters |
| `--trace` | include each step's trace in the events file |

**Behavior.** Read and parse the steps file. Load the pack and create the
engine. Then, in order, call `ingest` for each `ingest` step and `tick` for
each `tick` step, and after the last step `snapshot()`. No other engine call,
no reordering, no clock read by the engine (the only clock is the input's).

**Events file.** One JSON object per line, in step order:
`{"step": <index from 0>, "events": [...]}`, with `"trace": [...]` added when
`--trace` is given; then one last line `{"snapshot": {...}}`. Values are what
the engine returns; numbers compare as in `spec/vector-format.md` (relative
1e-6), so number formatting is free. The harness checks this file against
the Python runner's.

**Standard output.** Exactly one line, a JSON object of counters, and
nothing else (diagnostics go to standard error):

| Key | Value |
|---|---|
| `engine` | `python`, `rust`, `go`, `java`, `cpp`, `erlang` or `zig` |
| `function`, `pack` | as given (`pack`: the directory's base name) |
| `steps`, `ingest`, `tick` | number of steps, of ingest steps, of tick steps |
| `events`, `trace_records` | total events and trace records the engine returned |
| `parse_ns` | reading and parsing the steps file, monotonic clock, nanoseconds |
| `load_ns` | loading the pack and creating the engine |
| `run_ns` | from before the first `ingest`/`tick` to after `snapshot()`: the engine calls only, not writing the events file |

**Exit status.** 0 on success. Non-zero, with a message on standard error,
for an unknown function, a pack that does not load, or a steps file that
does not parse; the counters line is then not required.

**Memory.** Measured by the harness from the OS (peak resident set of the
`run` process and its children); the runner reports none. A `run` script
should `exec` the runner so that the measured process is the runner itself.

`run_python.py` is the reference implementation of this contract.
