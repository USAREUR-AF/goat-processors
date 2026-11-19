# goat-correlator

Status: Written, version 0.1. Python engine built and passing every vector;
the Rust, Go, Java, C++, Erlang and Zig engines are designed, not built.

goat-correlator decides when track reports from different sources describe
the same object, groups them, and keeps one estimate per group. It reads the
shared-model entities that [goat-transformers](https://github.com/USAREUR-AF/goat-transformers)
decodes from any message format, so a radar track, an ADS-B report and a CoT
event can be correlated with one another.

Every decision is explainable from the output. Each test the engine runs is a
trace record naming the two tracks, the test, the value it computed, the limit
and the result, and `snapshot()` returns the whole state, including each
track's filter. The engine is deterministic: its only clock is the time in its
input, so replaying the same input gives the same events and trace in every
language.

## Layout

| Path | What |
|---|---|
| `spec/correlator-spec.md` | the specification every engine implements |
| `spec/vector-format.md` | the conformance vector format |
| `spec/load-vectors/` | pack files that must load, or must fail to load |
| `packs/<name>/pack.def` | a rule set: which tests run, with which parameters |
| `packs/<name>/vectors/` | scenarios with their exact expected events, trace and final state |
| `engines/<language>/` | one independent engine per language |
| `tools/make-vectors.py` | the scenarios, with their decisions stated by hand |

## Packs

| Pack | Gate | Use |
|---|---|---|
| `gnn` | the reported track inside the other track's predicted 99 % uncertainty region | sources that report position error |
| `window` | distance below a window that grows with both tracks' error, in the shape of the Link 16 correlation window | sources with coarse or fixed error |

## Running the vectors

```
cd engines/python && PYTHONPATH=src python3 -m unittest discover -s tests
```
