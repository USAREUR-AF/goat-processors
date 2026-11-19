# goat-correlator: Erlang engine

An implementation of `spec/correlate.md` (version 0.5), method `confirm`, and
`spec/correlate-assign.md` (version 0.3), method `assign`, in Erlang/OTP, standard library
only. The pack's `method` line selects which runs. JSON is read with OTP 27's `json` module.

| File | Contents |
|---|---|
| `src/correlator.erl` | `load_pack/1`, `new/1`, `ingest/2`, `tick/2`, `snapshot/1`: reports, tests, association, events, trace, snapshot |
| `src/correlator_assign.erl` | method `assign`: memberships and histories, per-source ranked assignments (every assignment enumerated, then ordered by the Ranking rule), the multi-frame window and commit, inverse-variance fused estimate, its events, trace and snapshot |
| `src/correlator_estimate.erl` | an entity's estimate: one filter, or the two-model filter (`manoeuvre` line) with mixing, likelihood, mode probabilities, combination and prediction |
| `src/correlator_filter.erl` | the local plane frame and the two-axis constant-velocity Kalman filter |
| `src/correlator_pack.erl` | `pack.def` parsing and validation |
| `src/correlator_vectors.erl` | the vector runner |

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

Builds, then runs every scenario vector under `packs/correlate-*/vectors/`
(each step's events and trace, then the final snapshot) and every load vector under
`spec/correlate-load-vectors/`, using the structural comparison of
`spec/vector-format.md`. It prints `PASS` or `FAIL` per vector, the path of the
first mismatch for a failing vector, and a summary line, and exits non-zero if
any vector fails.

Open points and any vector that disagrees with the specification are in
`DISAGREEMENTS.md`.

## Note on OTP 27.3

OTP 27.3.4.6's compiler drops the code that follows a `lists:mapfoldl/3` call
whose result is then matched in a `case`, returning the `mapfoldl` result
directly. The engine uses explicit recursion in those places instead.
