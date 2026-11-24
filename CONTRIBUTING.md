# Contributing

goat-processors is a set of functions, each defined by a specification and
checked by vectors (test cases with their exact expected output) that seven
independent engines must reproduce exactly. A
contribution keeps three things true: every engine passes every vector, every
decision is in the trace, and every engine is written from the specification
alone.

The specification and the hand-stated decisions are the reference; every
vector is computed by the Rust engine and accepted only when all seven
engines agree. Each generator, `tools/make-<function>-vectors.py`, states its
scenarios' decisions by hand, runs the Rust engine's runner
(`engines/rust/runner/run`) to compute each vector, refuses a vector whose
events break those decisions, and writes it only when every engine's runner
gives the same events, trace and snapshot (`tools/consensus.py`, with the
comparison of `spec/vector-format.md`). Load vectors state their expected
result by hand; the generator writes them only when every engine's own vector
test command passes.

The words used below (pack, vector, trace record, track, tick) are defined in
the README, [Words used here](README.md#words-used-here); the correlate methods
and packs are in [Methods and packs](README.md#methods-and-packs).

## Contribute a measurement or an improvement

Start at [reviews/README.md](reviews/README.md): replicate a published number,
improve a pack or add a measurement. One command measures, compares and writes
the record; CI measures it again.

## Before you open a pull request

| Check | Command |
|---|---|
| your function's vectors are what its generator writes, and all seven engines agree on them | `python3 -I tools/make-<function>-vectors.py && git diff --exit-code -- packs spec` (needs the seven toolchains of the README's conformance table) |
| the engines you changed pass every vector | the command for that engine in the README's conformance table |
| the replay viewer still replays every vector | `python3 -I tools/explain/test_explain.py` |
| your performance records hold | `python3 -I tools/review/review.py check --rerun reviews/<yours>.json` |
| the fuse, filter and quality results are current | `python3 -I tools/bench/functions.py check` |
| the README and the figures are current | `python3 -I tools/readme/make-readme.py && python3 -I docs/figures/make-figures.py && git diff --exit-code` |

Commits are signed, carry a `Signed-off-by` line (`git commit -s`), and follow
Conventional Commits (`feat(fuse): ...`, `fix(rust): ...`, `docs: ...`). Pull
requests merge on green checks only.

## Add a function

One function is one branch and one pull request. The pull request carries the
specification, the packs, the vectors and all seven engines, so `main` passes
on every merge.

| Step | Files |
|---|---|
| 1. Write the specification: operations, events, trace records, snapshot, pack grammar, load errors, and an open-points list | `spec/<function>.md`, one row in `spec/README.md` |
| 2. Write the scenarios, each with its decisions stated by hand, and the packs | `tools/make-<function>-vectors.py` (using `tools/consensus.py`), `packs/<function>-<name>/pack.def` |
| 3. Build the Rust engine for the function from step 1, with its runner (the runner contract of `tools/perf/README.md`) | `engines/rust/` |
| 4. Compute the vectors and load vectors with the Rust engine: `python3 -I tools/make-<function>-vectors.py --rust-only`. The generator refuses a vector whose events differ from the stated decisions | `packs/<function>-<name>/vectors/`, `spec/<function>-load-vectors/` |
| 5. Build the six other engines from the specification, the packs and the vectors only (see the clean-room rule), each with its runner and its vector test | a new module, a runner and a test in each `engines/<language>/` |
| 6. Run the generator without `--rust-only`: it writes a vector only when all seven engines agree, and prints each disagreement as engine, step, field, expected and got. Add one step to the `vectors-current` job | `.github/workflows/conformance.yml` |
| 7. Register the Python module so the replay viewer can show the function step by step | the `ENGINES` table in `tools/explain/explain.py` |
| 8. Regenerate the README and the figures | `python3 -I tools/readme/make-readme.py`, `python3 -I docs/figures/make-figures.py` |

A function follows the rules every function shares:

- The only clock is the time in the input. No wall clock and no randomness.
- Every collection is visited in an order the specification states.
- Every test or measurement is a trace record with its inputs, the value it
  computed, its limit and its result.
- `snapshot()` returns the whole state; replaying the same input gives the same
  snapshot.
- Each engine's runner for a function reads only that function's packs,
  `packs/<function>-*`.

## Continuous integration

`.github/workflows/conformance.yml` runs on every pull request and every push
to `main`:

- `vectors-current` installs the Rust toolchain and runs every generator with
  `--rust-only`: the Rust engine recomputes every vector, every hand-stated
  decision is checked again, and `tools/vectors_match.py` compares the
  committed files with what the generators write, as `spec/vector-format.md`
  compares vectors. Not byte for byte: the platform's library functions
  (`sin`, `cos`, `atan2`, `hypot`, `pow`, `exp`, `ln`) may differ in the last
  bit between machines (`spec/correlate.md`, Floats), and that comparison
  absorbs exactly that. Commit vectors the generators wrote; never edit one
  by hand.
- One job per engine runs that engine's own test on every scenario vector and
  every load vector, so all seven engines are checked against every vector.

Together they repeat the consensus rule on every change: the vectors are what
the Rust engine computes from the hand-stated scenarios, and every engine
agrees with them.

## Add a pack

A pack is a rule set: which of a function's tests run, with which parameters.
It holds no code and no expressions.

1. Write `packs/<function>-<name>/pack.def` in the grammar of the function's
   specification. Start it with comment lines that say what the pack is for
   and why each limit has its value.
2. Add scenarios for it to `tools/make-<function>-vectors.py`, each with its
   decisions stated by hand, and generate the vectors.
3. For a correlate pack, add its plain description to `PACKS` in
   `tools/readme/make-readme.py`: what it does and what it adds over the pack
   it extends. The README generator refuses to run without it.
4. Every engine must pass them. A pack that needs a test the specification
   does not define is a specification change: add the test to the
   specification first, with its trace record.

## Add an engine

An engine is a complete implementation of every function in one language,
using only that language's standard library.

1. Create `engines/<language>/` with a README stating how to build it and run
   every vector.
2. Implement each function from its specification, `spec/vector-format.md`,
   the packs and the vectors.
3. Add a runner that checks every scenario vector (events, trace, final
   snapshot, with the number tolerance of `spec/vector-format.md`) and every
   load vector, and a job for it in `.github/workflows/conformance.yml`.
4. Add the language to the `ENGINES` lists in `tools/readme/make-readme.py`
   and `docs/figures/make-figures.py`.

## The clean-room rule

Every engine is written from the specification and the vectors, so that
seven engines agreeing is evidence that the specification is complete.
No engine is the reference: a vector is accepted only when all seven agree.

- An engine is written from `spec/`, the packs and the vectors only. Never read
  another engine's source or a vector generator while writing one.
- If an engine and a vector disagree, write the case in
  `engines/<language>/DISAGREEMENTS.md`: the vector, the step, what the
  specification says, and what the engine computes. Do not edit the vector or
  the specification to make an engine pass. The specification's author
  resolves the case, and a changed vector comes from a changed generator.
- Specifications are written in our own words and justify each rule on its
  own terms. Nothing in this repository names, quotes or paraphrases another
  product's source, files, types, symbols, parameter names or default values.
- Vectors use notional positions in open ocean and invented identifiers.

## License

By contributing you agree that your contribution is released under the
Apache License 2.0, as stated in [INTENT.md](INTENT.md) and [NOTICE](NOTICE).
