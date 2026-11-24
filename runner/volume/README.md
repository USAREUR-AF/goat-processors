# runner/volume

Status: Built. The volume test's input and budget. The figures and what they
mean are in [../README.md](../README.md), "Output volume".

| File | What it holds |
|---|---|
| `scenario.py` | the input: N objects seen by a radar and a beacon for 120 s, seeded (`python3 -I scenario.py N SECONDS OUT.json`) |
| `budget.json` | the ceilings the test checks, and the run that set them (`measured`). Written by `budget.py`, not by hand |
| `budget.py` | writes `budget.json` and the README's volume table from a run's results; `--check` fails when the two differ |

The test is `../tests/volume.rs`: `cargo test --release --test volume --
--ignored --nocapture` in `runner/`.

**To raise the budget** (a change sends or keeps more, on purpose):

1. Run the test at every size in the budget:
   `GP_VOLUME_SIZES=50,200,1000 cargo test --release --test volume -- --ignored --nocapture`.
2. `python3 -I volume/budget.py target/volume/results.json` (from `runner/`).
   It rewrites `budget.json` and the README table; the rules for each
   ceiling are in its docstring.
3. In the commit message, say which figure rose, by how much, and why.

The budget is for 120 s of input. A run with `GP_VOLUME_SECONDS` set to
another length prints its figures and does not compare them, and `budget.py`
refuses its results.
