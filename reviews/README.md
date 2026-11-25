# Performance review

How well each function works, measured, and how to add to that. Everything
here runs on public data with Python 3.12 and no packages. A first
contribution takes two commands and changes one file.

| You want to | Do this | Files you change |
|---|---|---|
| see where things stand | `python3 -I tools/review/review.py status` | none |
| confirm the published numbers on your machine | [Replicate](#replicate) | one file in `reviews/` |
| try a better setting | [Improve a pack](#improve-a-pack) | a pack, one file in `reviews/` |
| measure something nobody has | [Add a measurement](#add-a-measurement) | `tools/bench/`, one file in `reviews/` |
| score your own tracker against the packs | [Compare your tracker](#compare-your-tracker) | none |
| prepare for a real sensor feed | [docs/real-feeds.md](../docs/real-feeds.md) | `tools/feeds/` |
| find something to work on | [Open work](#open-work) | |

A result that did not help is worth recording too: it saves the next person
the same work.

## Where things stand

| Function | Accuracy measured on | Held-out set | Results |
|---|---|---|---|
| correlate | 691 tuning scenarios, 663 held-out | yes | [docs/benchmark.md](../docs/benchmark.md) |
| fuse | the true grouping given: position error, and whether the stated error is honest | no | [docs/benchmark-functions.md](../docs/benchmark-functions.md#fuse) |
| filter | keep or drop against the true position, near a boundary | no | [docs/benchmark-functions.md](../docs/benchmark-functions.md#filter) |
| quality | eight rules against injected faults of graded size | no | [docs/benchmark-functions.md](../docs/benchmark-functions.md#quality) |

Speed is in [docs/performance.md](../docs/performance.md). Every score's
formula is in [tools/bench/README.md](../tools/bench/README.md).

## Replicate

```sh
python3 -I tools/review/review.py record replicate-PACK-YOURSYSTEM PACK --kind replicate \
  --question "Do the committed PACK results reproduce on YOURSYSTEM?" \
  --finding "Yes: every pooled measure of every group matches."
```

This measures the pack, compares it with the results committed on `main` and
writes `reviews/replicate-PACK-YOURSYSTEM.json`. Commit that file and open a
pull request. A correlate pack takes one to ten minutes, the others seconds to
a minute. If it does not match, use `--kind measure` and say what differs:
that is the more useful result.

## Compare your tracker

Any tracker can be scored on the same scenarios as the packs:

```sh
python3 -I tools/bench/bench.py generate --out build/bench/scenarios
# run your tracker on each scenario; write <scenario>.events.json per scenario
python3 -I tools/review/compare.py build/my-tracker
```

The events file is in [tools/bench/README.md](../tools/bench/README.md#events-file).
`compare.py` scores each group whose scenarios all have an events file and sets
it against `correlate-assign-time`, `correlate-gnn` and `correlate-window`
(others with `--against`), with the rule below. A pack scored this way gives
its own published numbers; `tools/review/test_compare.py` checks that. Post
the output in an issue with the "Performance result" form.

On real data, where no truth exists, `tools/feeds/agree.py` measures how far
two outputs agree, and either can be your tracker's events file
([docs/real-feeds.md](../docs/real-feeds.md#agreement-between-correlators)).

## Improve a pack

1. Copy the pack: `cp -r packs/correlate-assign-time packs/correlate-mine`,
   remove its `vectors/` directory, and change `pack` and one setting in
   `pack.def`.
2. Measure it against the one you started from, as often as you like:

   ```sh
   python3 -I tools/review/review.py try correlate-mine --against correlate-assign-time --group random
   ```

   A measure is **better** or **worse** only when the two 95 % intervals do
   not overlap. Anything else is no difference shown, whichever way the number
   moved.
3. Record it with `record`, `--kind improve` and `--against`. The tool refuses
   `improve` when no measure is better. It lists every worse measure, and the
   finding must say why the trade is worth it.
4. Open a draft pull request with the record and the pack. Once a maintainer
   has run the held-out set, add the vectors and the README line
   ([CONTRIBUTING.md](../CONTRIBUTING.md#add-a-pack)).

A filter, fuse or quality pack is measured once it is named in `PACKS` in
`tools/bench/functions.py`.

To change an engine's method and not only a setting, change the specification
first ([CONTRIBUTING.md](../CONTRIBUTING.md)); `try PACK` with no `--against`
then compares your checkout with `main`. Method changes land in all seven
engines together, so open an issue before you start.

## Add a measurement

Add a case to `tools/bench/functions.py` (or a scenario family to
`tools/bench/dataset.py` for correlate). Four things make it acceptable:

| Rule | Why |
|---|---|
| The right answer comes from how the case was generated, never from an engine | an engine cannot grade itself |
| Cases lie on both sides of what is being decided | a case that is always positive cannot show a false alarm |
| Seeds are public and the generator uses the bench's own `Rng` | anyone gets the same data |
| A test in `test_functions.py` checks the scorer against an answer known by hand | a scorer has errors too |

## What happens to your pull request

| Step | Who | What |
|---|---|---|
| 1 | CI | checks every record, and measures each new record again from your branch: counts must match exactly, other numbers to one part in a million |
| 2 | a maintainer | reads the question, the finding and the worse list |
| 3 | a maintainer, for `improve` | runs the held-out set. The seeds are private so that nothing is tuned on them, and they are replaced after each release |
| 4 | a maintainer | merges, or says in the pull request which measure decided against it |

A pull request that changes only `reviews/` and `packs/` touches none of the
[paths that need a security review](../.github/contributor-trust/sensitive-paths.txt).
A change under `tools/` does.

Records are never edited after they merge. A later result is a new record, so
contributors never conflict over a file.

## What counts

| Claim | Needs |
|---|---|
| "better" | intervals that do not overlap, on the tuning set, confirmed on the held-out set where one exists |
| "no worse" | an empty worse list |
| "reproduces" | a `replicate` record |
| "faster" | `tools/perf/perf.py` before and after on one quiet machine, with the pull request |

Do not use real sensor recordings, real positions or real identifiers in a
case or a record. Recorded data needs a public source whose license allows it,
as `tools/bench/recorded.py` does. The record holds the Python version, the
system and the machine type, and nothing else about your computer.

## Open work

Rows 1 to 8 have a number today, so anyone can show a better one.

| # | Work | Number today | Done when |
|---|---|---|---|
| 1 | correlate: three sensors, at least one understating or omitting its error | 54 of the 55 tuning random scenarios with F1 below 0.9 (`correlate-assign-time`) | random F1 is better, no family worse |
| 2 | correlate: identity swaps | `correlate-assign-time` 471 swaps, `correlate-window` 122 (held-out random) | swaps better, false merges no worse |
| 3 | correlate: formations | F1 0.942 (held-out, `correlate-assign-time`) | formation F1 better |
| 4 | correlate: 50 to 1,000 objects | no assign pack finishes within 300 s in the Python engine | the 50-object scenario finishes |
| 5 | fuse: the stated error is too small with honest sensors | error ratio 16.3 (`fuse-independent`); 1 is honest | error ratio nearer 1, position error no worse |
| 6 | fuse: a member whose track number moved to another object | position error 1689 m (`fuse-independent`), 120 m without one | position error better in that row |
| 7 | quality: `speed-mismatch` false alarms | precision 0.167 | precision better, recall no worse |
| 8 | quality: `overconfident` false alarms | precision 0.630 | precision better, recall no worse |
| 9 | filter: what `filter-thin` costs the picture | not measured | a case in `functions.py` |
| 10 | a held-out set for fuse, filter and quality | none exists | maintainer work: private seeds, as for correlate |
