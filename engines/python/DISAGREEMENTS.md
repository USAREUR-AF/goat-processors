# Disagreements and spec ambiguities (Python engine)

Points where the Python engine found the specification silent or ambiguous
during the refactor (round-refactor). Each is for proc-coord. None changes
the spec, a pack or a vector, and none changes any output: the engine's
behavior on these inputs is as it was before the refactor, except where
noted (an exception type only).

## 1. A longitude that adding or subtracting 360 cannot bring into range

**Spec.** correlate.md, Frame: `dlon`, and the output `lon`, are "brought
into (-180, 180] by adding or subtracting 360"; filter.md, Geometry, the
same for `wrap`. Neither bounds `lat`, `lon`, `speed_ms` or a time step.

**Finding (fuzzing, tests/test_fuzz.py, IntakeFuzz).** When the value to
wrap is so large that `x - 360 == x` in binary64 (about 1e17 or more), or
merely huge (1e15 takes hours), the loop the spec describes does not end.
Reports reach it three ways: a `lon` of that size; a position predicted far
away by a large `speed_ms` or time step; and any east motion at a pole,
where `cos(lat)` is about 6e-17 (correlate output with the frame reference
at a pole; filter `near` with a reference entity at a pole). Every engine
that follows the spec literally loops forever on one such report.

**Python engine.** Unchanged (it loops). The fuzzer keeps positions within
±89° latitude and numbers to magnitudes below this, and says why.

**For proc-coord.** Either bound the inputs (a `lat` outside [-90, 90] or a
`lon` outside [-180, 180] rejected like a missing key) or define the wrap as
a remainder (`x - 360 * round(x / 360)` with a stated tie rule), with a
vector for each. Either is a spec version bump.

## 2. Numbers whose square overflows binary64

**Spec.** correlate.md, Floats: binary64, the formulas in order. A report's
`ce` must be above 0; no upper bound. Nothing says what happens on overflow.

**Finding (fuzzing).** A `ce` of 1e308 makes `ce²` infinite; with the
two-model filter the likelihoods become `-inf`, the mode probabilities NaN,
and the next report of that entity finds no model with a probability above 0
(`max()` of nothing): the Python engine raises `ValueError` from `ingest`.
The one-model filter and fuse carry the infinities and NaNs into the output.

**Python engine.** Unchanged. The fuzzer keeps report numbers whose square
is finite.

**For proc-coord.** A bound on `ce` (and on `speed_ms`, `hae`), or a rule
for non-finite intermediate values.

## 3. Integers too long to convert in pack.def

**Spec.** fuse.md, Pack: `stale_ms` "one integer, 0 or above", no upper
bound; quality.md, Pack: `window_ms`, `min_samples`, `forget_ms`, `for` the
same. filter.md, Values: integers above the signed 64-bit range are a load
error.

**Finding (fuzzing, PackDefFuzz).** An integer of more than 4300 digits (the
default of Python's `sys.int_info.default_max_str_digits`) made the filter,
fuse and quality parsers raise `ValueError` instead of `PackError`.

**Python engine.** Fixed in the exception type only: filter now refuses it
as out of range (as the spec says, leading zeros ignored); fuse and quality
refuse it as "integer too long". The pack did not load before and does not
load now; no vector, load vector or golden file changes. A fuse or quality
integer of 20 to 4300 digits still loads, as before.

**For proc-coord.** An upper bound (the signed 64-bit range, as filter has)
for every pack integer of fuse and quality, with a load vector.
