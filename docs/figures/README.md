# Figures

Status: Built. `make-figures.py` draws every figure in this directory from the
tree: the vectors, the packs, the engine directories, and replays of vectors
through `engines/python`. Nothing in a figure is typed by hand. Each figure is
written in a light and a dark variant for a `<picture>` element.

```sh
python3 -I docs/figures/make-figures.py           # write the SVG files
python3 -I docs/figures/make-figures.py --check   # exit 1 if a committed file is out of date
```

| Figure | Shows | Data |
|---|---|---|
| `processing-layer` | where goat-processors sits: message formats, goat-transformers, the shared model, the four functions with their status, the outputs | source names and report keys from every vector; function status from `packs/` and `spec/` |
| `correlate-decision` | one correlate decision: two sources' reports, the predicted 99 % region, the trace records, the group that forms | `packs/correlate-gnn/vectors/04-separation-dissolves.json`, step 3. The generator recomputes the gate value from the snapshots and refuses to draw if it differs from the trace record |
| `assign-matrix` | one assignment: the cost matrix with its forbidden entries and `new_cost`, the chosen assignment against nearest-first | `packs/correlate-assign/vectors/25-assign-least-total-not-nearest-first.json`, step 5 |
| `seven-engines` | the seven engines checking each other against one set of vectors | counts of vectors, steps, trace records and load vectors; the engine directories |

A function's status in `processing-layer` is Built when it has vectors under
`packs/<function>-*`, Written when `spec/<function>.md` exists, and Designed
otherwise. Regenerate after a function PR merges.

## Checks

Each figure was rendered in headless Chromium as an `<img>` at 830 px wide in
both themes and inspected. Text is at least 13 units on an 880-unit canvas, so
at least 12 px at 830 px.
