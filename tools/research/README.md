# tools/research

Status: Built. Prototypes of published correlation and fusion methods,
scored on the benchmark before any of them reaches a spec. The survey, the
results and the decisions are in
[docs/research/correlation-and-fusion-methods.md](../../docs/research/correlation-and-fusion-methods.md).

A prototype is evidence, not an engine. It is a subclass of the Python
engine and changes only what its method needs; the engine is not
edited. An adopted method reaches the seven engines only through a spec and
vectors.

Standard library only. Run every command with `python3 -I`.

| File | What it holds |
|---|---|
| `variants.py` | the prototypes and `VARIANTS`, the registry of named variants (pack, engine class, options) |
| `research.py` | the harness: `run`, `compare`, `perf` |

## Commands

| Command | Does |
|---|---|
| `research.py run VARIANT ... [--set bench\|holdout\|all] [--jobs N]` | runs each variant on the scenarios, scores each run with `tools/bench/score.py`, writes `build/research/<set>/<variant>.json` |
| `research.py compare BASE VARIANT [--set ...] [--boot N] [--json]` | pooled measures per set (named, random, time, held-out), the paired bootstrap interval of each difference, and the named weaknesses |
| `research.py perf VARIANT ... [--repeats N] [--size large\|smoke]` | engine time on the `tools/perf` scenario; repeats interleaved across variants; the median and the median ratio to the first variant |

## Sets

| Set | Scenarios |
|---|---|
| `bench` | the 78 benchmark scenarios of `tools/bench` (21 named, 50 random, 7 time) |
| `holdout` | 50 more random scenarios from seed 20261120, the same generator; never used to choose a parameter |
| `all` | both |

## Noise

The engines are deterministic, so two runs of one variant give the same
bits; `run` of a reference pack reproduces `docs/figures/bench/results.json`
exactly. The noise that matters is the choice of scenarios. `compare`
draws the scenarios of a set again with replacement (1,000 draws by
default, a fixed seed), pools both variants over each draw, and reports
the 2.5 % and 97.5 % points of the difference. A difference whose interval
excludes 0 is beyond noise.

## Adding a prototype

Subclass `AssignEngine` or `Engine` from `engines/python`, override the
fewest methods the method needs, add a trace record for each new decision,
and add a row to `VARIANTS`. Run it against its base with `run` and
`compare` on `--set all`.
