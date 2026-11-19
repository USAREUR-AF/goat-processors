# goat-correlator: Erlang engine

An implementation of `spec/correlate.md` (version 0.4), method `confirm`, and
`spec/correlate-assign.md` (version 0.2), method `assign`, and of the function
`spec/fuse.md` (version 0.1), in Erlang/OTP, standard library only. In a correlate pack the `method` line selects which method runs; fuse is a separate module with its own packs (`packs/fuse-*`). JSON is read with OTP 27's `json` module.

| File | Contents |
|---|---|
| `src/correlator.erl` | `load_pack/1`, `new/1`, `ingest/2`, `tick/2`, `snapshot/1`: reports, tests, association, events, trace, snapshot |
| `src/correlator_assign.erl` | method `assign`: system tracks, per-source least-cost assignment (Hungarian method with potentials), inverse-variance fused estimate, its events, trace and snapshot |
| `src/correlator_filter.erl` | the local plane frame and the two-axis constant-velocity Kalman filter |
| `src/correlator_pack.erl` | `pack.def` parsing and validation |
| `src/correlator_vectors.erl` | the correlate vector runner, and the structural comparison of `spec/vector-format.md` |
| `src/fuse.erl` | fuse: `load_pack/1`, `new/1`, `ingest/2`, `tick/2`, `snapshot/1`: normalised reports, groups, staleness, the five kinematics methods, attributes, events, trace, snapshot; Frame and filter from `correlator_filter` |
| `src/fuse_pack.erl` | fuse `pack.def` parsing and validation (`spec/fuse.md` "Pack") |
| `src/fuse_vectors.erl` | the fuse vector runner |

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

Builds, then runs two runners. The correlate runner reads only
`packs/correlate-*/vectors/` and `spec/correlate-load-vectors/`; the fuse runner
reads only `packs/fuse-*/vectors/` and `spec/fuse-load-vectors/`. Each runs every
scenario vector (each step's events and trace, then the final snapshot) and every
load vector, using the structural comparison of
`spec/vector-format.md`. It prints `PASS` or `FAIL` per vector, the path of the
first mismatch for a failing vector, and a summary line per runner, and exits non-zero
if any vector fails.

Open points and any vector that disagrees with the specification are in
`DISAGREEMENTS.md`.

## Note on OTP 27.3

OTP 27.3.4.6's compiler drops the code that follows a `lists:mapfoldl/3` call
whose result is then matched in a `case`, returning the `mapfoldl` result
directly. The engine uses explicit recursion in those places instead.
