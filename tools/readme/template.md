# goat-processors

{{badge}}

goat-processors holds the functions that work on track data after it has been
translated: correlation, fusion, filtering, and quality measurement with the
actions that follow from it. [goat-transformers](https://github.com/USAREUR-AF/goat-transformers)
is the layer beneath it and translates messages between formats into one
shared model; goat-processors reads that model. Each function is a written
specification, a set of rule packs, and conformance vectors that {{n_engines}}
independent engines (Python, Rust, Go, Java, C++, Erlang, Zig) reproduce
exactly, down to every trace record.

{{figure:processing-layer}}

## Functions

{{functions}}

Each function runs as `load_pack`, then `ingest(report)` and `tick(now_ms)`,
each returning events and trace records, and `snapshot()`, which returns the
whole state.

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

The correlate packs are scored against ground truth on generated scenarios:
crossing, formation, splitting and turning objects; sensors with understated
or absent error, bias, latency, low detection, track number swaps and false
tracks; and sensors whose clocks are offset, drifting or free-running, or
whose reports arrive out of order. Every score and its formula is in [docs/benchmark.md](docs/benchmark.md),
which `tools/bench/bench.py report` writes.

{{benchmark}}

{{figure:bench}}

## Design principles

| Principle | In practice |
|---|---|
| Deterministic | The only clock is the time in the input. Every collection is visited in an order the specification states. The same input gives the same output and trace in every language. |
| Rules are data | A pack (`packs/<function>-<name>/pack.def`) names fixed, specified tests and their parameters. A pack holds no code and no expressions. |
| Every decision is traced | Every test is a trace record with its inputs, value, limit and result. `snapshot()` returns the whole state, including each track's filter. |
| Engines check each other | {{n_engines_word}} engines written apart must reproduce every vector: events, trace and final snapshot, numbers within a relative {{tolerance}}. |
| Standard library only | No engine or tool depends on a third-party package. |

## Layout

| Path | What |
|---|---|
| [`spec/`](spec/) | one specification per function, the shared [vector format](spec/vector-format.md), load vectors |
| [`packs/`](packs/) | {{n_packs}} rule packs, each with its `pack.def` and its scenario vectors ({{n_vectors}} in all) |
| [`engines/`](engines/) | one independent engine per language, each with its test runner |
| [`tools/`](tools/) | the vector generators, the replay viewer (`explain/`), the benchmark (`bench/`), the performance harness (`perf/`), this README's generator (`readme/`) |
| [`docs/`](docs/) | the benchmark results, the [performance](docs/performance.md) baseline and the figures, each written by a script |

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) explains how to add a function, a pack or
an engine, and the clean-room rule every engine follows.

## License

Apache License 2.0; see [LICENSE](LICENSE), [NOTICE](NOTICE) and
[INTENT.md](INTENT.md). Portions written by U.S. Federal government employees
within the scope of their employment are in the public domain in the United
States.
