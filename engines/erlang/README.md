# goat-correlator: Erlang engine

An implementation of `spec/correlator-spec.md` in Erlang/OTP, standard library
only. JSON is read with OTP 27's `json` module.

| File | Contents |
|---|---|
| `src/correlator.erl` | `load_pack/1`, `new/1`, `ingest/2`, `tick/2`, `snapshot/1`: reports, tests, association, events, trace, snapshot |
| `src/correlator_filter.erl` | the local plane frame and the two-axis constant-velocity Kalman filter |
| `src/correlator_pack.erl` | `pack.def` parsing and validation |
| `src/correlator_vectors.erl` | the vector runner |
| `DISAGREEMENTS.md` | vector/spec disagreements, and how open points are resolved |

The engine state is a value: `ingest(Report, State)` and `tick(NowMs, State)`
return `{Events, Trace, NewState}`.

## Build

Requires OTP 27 (`erl`, `erlc`).

```
engines/erlang/build.sh
```

Compiles `src/*.erl` into `engines/erlang/ebin/`.

## Run the vectors

```
engines/erlang/run_tests
```

Builds, then runs every scenario vector under `packs/*/vectors/` (each step's
events and trace, then the final snapshot) and every load vector under
`spec/load-vectors/`, using the structural comparison of
`spec/vector-format.md`. It prints `PASS` or `FAIL` per vector, the path of the
first mismatch for a failing vector, and a summary line, and exits non-zero if
any vector fails.

## Note on OTP 27.3

OTP 27.3.4.6's compiler drops the code that follows a `lists:mapfoldl/3` call
whose result is then matched in a `case`, returning the `mapfoldl` result
directly. The engine uses explicit recursion in those places instead.
