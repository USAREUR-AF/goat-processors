# goat-processors

{{badge}}

goat-processors holds the functions that work on track data after it has been
translated: correlation, fusion, filtering, and quality measurement with the
actions that follow from it. [goat-transformers](https://github.com/USAREUR-AF/goat-transformers)
is the layer beneath it and translates messages between formats into one
shared model; goat-processors reads that model. Each function is a written
specification, a set of settings files (packs), and test cases (vectors) that
{{n_engines}} independent engines (Python, Rust, Go, Java, C++, Erlang, Zig)
reproduce exactly, down to the record of every test they run.

{{figure:processing-layer}}

## Words used here

| Word | Meaning |
|---|---|
| report | one message from one source about one object, after translation: its time, position, reported position error (`ce`, meters) and identity keys |
| track | the reports of one source about one object, under that source's track number; named `<source>/<uid>`, for example `radar-1/T1` |
| motion filter | a small Kalman filter kept for each track: it predicts where the track will be, and how uncertain that prediction is |
| tick | a call `tick(now_ms)` that moves the function's clock to `now_ms` and returns its output for that moment |
| group, system track | the output for one object: the tracks judged to describe it, with one estimate. The per-report method makes groups of two or more tracks; the assignment method keeps one system track per object, even for a track seen by one source |
| pack | a named settings file for one function, `packs/<function>-<name>/pack.def`: which tests run and with which limits. A pack holds no code |
| vector | a test case: a list of inputs with the exact events, trace and final state every engine must produce |
| trace record | one line per test the engine ran: what it compared, the value it computed, the limit and the result |

## Functions

{{functions}}

Each function runs as `load_pack`, then `ingest(report)` and `tick(now_ms)`,
each returning events and trace records, and `snapshot()`, which returns the
whole state.

## Methods and packs

The correlate function decides which tracks from different sources describe
the same object. It has two **methods**, chosen by a line in the pack:

| Method | How it decides |
|---|---|
| `confirm` (per report) | each new report is tested against the other sources' tracks; a pair is grouped after passing on two reports in a row, and ungrouped after failing twice |
| `assign` (per tick) | at each tick, all of one source's tracks are placed together by the least total cost (an exact minimum-cost assignment), so one close track cannot take another's match; every track is in exactly one system track |

Each **pack** below is one set of correlate settings. Most extend another
pack and add one capability. F1 is the [benchmark](#benchmark)'s association
score, from 0 to 1: how well a pack puts the tracks of one object together
and keeps different objects apart, on three sets of scenarios (named, random,
and time quality, where sensor clocks are wrong).

{{methods_and_packs}}

## Quick start

Run every vector in one language. Each engine uses only its language's
standard library.

```sh
cd engines/python && PYTHONPATH=src python3 -m unittest discover -s tests
```

The command for each language is in the conformance table below.

Open a vector in the replay viewer. It writes one HTML page that works offline:

```sh
python3 -I tools/explain/explain.py packs/correlate-gnn/vectors/04-separation-dissolves.json
# open 04-separation-dissolves.html in a browser

python3 -I tools/explain/explain.py --all build/explain   # every vector, with an index page
```

The page shows a plan view of every report and filter estimate with its
uncertainty ellipse, the groups as they form and dissolve, a step slider, and
for each step the input, the events, every trace record and the snapshot.
[tools/explain/README.md](tools/explain/README.md) lists its options,
including replaying a benchmark run against its ground truth.

## Run it on a machine

The [runner](runner/README.md) runs the functions as a service. It reads
shared-model reports from the goat fabric, runs a declared pipeline (filter,
correlate, fuse, quality) on the Rust engine, and publishes system tracks and
quality marks. It installs on Ubuntu 24.04 from one `.deb`, is configured by
one file, and `goat-processors doctor` reports what is wrong.
[runner/INSTALL.md](runner/INSTALL.md) goes from a fresh machine to a healthy
runner, step by step; `runner/install.sh` does the same steps in one command.

## Every decision is observable

A function decides nothing that is not in its trace. Each test is a record of
what it compared, the value it computed, the limit and the result.

{{trace_example}}

{{figure:correlate-decision}}

The assignment method keeps a cost matrix at each tick and records every
entry and every choice:

{{figure:assign-matrix}}

## {{n_engines_word}} engines check each other

{{figure:seven-engines}}

The Python engine and `tools/make-*-vectors.py` write the vectors; each
generator states its scenarios' decisions by hand and refuses to write a
vector whose events differ from them. The other {{n_others_word}} engines are written from
the specification and the vectors alone, never from another engine's source.
An engine that disagrees with a vector records it in its `DISAGREEMENTS.md`;
the vector is changed only through the specification.

{{conformance}}

## Benchmark

The correlate packs are scored against ground truth on two separated sets of
scenarios. The **tuning set** is public and is the only one packs are tuned on.
The **evaluation set** comes from held-out seeds and gives every number below;
its seeds are published after each release and then replaced. Each set holds
500 random scenarios and the same families: formations that split and join,
shallow crossings and merges, 3 to 9 g turns, climbs and dives, stop-and-go
surface traffic, sensor dropouts, latency, out-of-order bursts, wrong stated
error and bias, scale up to 1,000 objects, clutter, mixed air, surface and
land traffic, track-number reuse and late sensors, and ships on recorded
public AIS tracks. Every score, its formula and its 95 % interval are in
[docs/benchmark.md](docs/benchmark.md), which `tools/bench/bench.py report`
writes; a difference counts only when the intervals separate. Pack names are
explained in [Methods and packs](#methods-and-packs).

| Measure | Meaning |
|---|---|
| pairwise F1 | at every tick, every pair of live tracks is checked: does the output put them together exactly when they are the same object? Precision is the share of output pairs that are right, recall the share of true pairs found; F1 is their harmonic mean, from 0 to 1, higher is better |
| false merge | two tracks of different objects put in one output track; counted each time it starts |
| missed merge | two tracks of one object kept apart for a whole stretch of at least 10 s |
| identity swap | an object's output track changes to another while the first still exists |
| GOSPA | the mean, over ticks, of the distance between output and true positions, with each error capped at 500 m and every missed or false track charged half the cap; lower is better |

{{benchmark}}

{{figure:bench}}

## Design principles

| Principle | In practice |
|---|---|
| Deterministic | The only clock is the time in the input. Every collection is visited in an order the specification states. The same input gives the same output and trace in every language. |
| Rules are data | A pack (`packs/<function>-<name>/pack.def`) names fixed, specified tests and their parameters. A pack holds no code and no expressions. |
| Every decision is traced | Every test is a trace record with its inputs, value, limit and result. `snapshot()` returns the whole state, including each track's filter. |
| Engines check each other | {{n_engines_word}} engines written apart must reproduce every vector: events, trace and final snapshot, numbers within a relative {{tolerance}}. |
| Standard library only | No engine or tool depends on a third-party package. The runner, which connects the engines to the fabric, is the one exception and lists its crates in [`runner/THIRD-PARTY.md`](runner/THIRD-PARTY.md). |

## Layout

| Path | What |
|---|---|
| [`spec/`](spec/) | one specification per function, the shared [vector format](spec/vector-format.md), load vectors |
| [`packs/`](packs/) | {{n_packs}} rule packs, each with its `pack.def` and its scenario vectors ({{n_vectors}} in all) |
| [`engines/`](engines/) | one independent engine per language, each with its test runner |
| [`tools/`](tools/) | the vector generators, the replay viewer (`explain/`), the benchmark (`bench/`), the performance harness (`perf/`), the research prototypes (`research/`), this README's generator (`readme/`) |
| [`runner/`](runner/) | the runner: a service for Ubuntu 24.04 that runs a pipeline of the functions on the goat fabric, with its `.deb`, [install guide](runner/INSTALL.md) and [deploy contract](runner/DEPLOY-CONTRACT.md) |
| [`docs/`](docs/) | the benchmark results, the [performance](docs/performance.md) baseline and the figures, each written by a script; the [methods survey](docs/research/correlation-and-fusion-methods.md) |

## Working with AI agents

An AI agent here is a program, usually driven by a language model, that reads
data and acts through tools. The processors stay fast and exact, with no model
inside the engines. The design connects agents at the edges, through the same
doors a person uses, and gives every agent action the identity it acts for and
an entry in a log.

{{agentic}}

The runner works with no agent at all, and in the design every agent feature
stays optional. Each site declares which model its agent features may use, one
on its own machines or one hosted by a provider, and the highest level of data
that may be sent to it. {{agentic_design}}

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) explains how to add a function, a pack or
an engine, and the clean-room rule every engine follows.

## License

Apache License 2.0; see [LICENSE](LICENSE), [NOTICE](NOTICE) and
[INTENT.md](INTENT.md). Portions written by U.S. Federal government employees
within the scope of their employment are in the public domain in the United
States.
