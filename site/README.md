# site

The landing page published to GitHub Pages by `.github/workflows/pages.yml`.
One static page: no build step beyond copying, no framework, no external
requests, no web fonts.

## Files

| File | What it is |
|---|---|
| `index.html` | the page |
| `assets/site.css` | its styles, light and dark (`prefers-color-scheme`) |
| `assets/hero.js` | the copy buttons, and the hero's replay of one vector |
| `assets/icon.svg` | the page icon |
| `assets/from-tree/` | git-ignored; written by `build.py`: the figures from `docs/figures/` and the vector the hero replays |
| `build.py` | copies `assets/from-tree/` and checks every number on the page against the tree |

## Preview

```sh
python3 -I site/build.py
python3 -m http.server 8000 --directory site    # then open http://127.0.0.1:8000/
```

## Where each number comes from

Every number is in an element with `data-measure="<key>"`; `build.py` measures
the key from the tree and fails if the page says something else.

| Key | On the page | Measured as |
|---|---|---|
| `engines` | engines | directories under `engines/` (`ls engines \| wc -l`) |
| `vectors` | scenario vectors | `ls packs/*/vectors/*.json \| wc -l` |
| `traces` | trace records | the sum of `len(step["trace"])` over every step of every vector |
| `packs` | settings packs | `ls packs/*/pack.def \| wc -l` |
| `f1-random`, `gospa-random` | the `assign-time` row of the random set | the first `assign-time` row of `docs/benchmark.md`, which `tools/bench/bench.py check` keeps current |

## Agent interface statuses

Every status in the "Working with AI agents" band is in an element with
`data-status="<id> ..."`. `build.py` checks that it shows the least-built
status, of Built, Written and Designed, among the interfaces it names in
`tools/readme/agentic.json`, and that every interface there appears on the
page. The README's section "Working with AI agents" is written from the same
file by `tools/readme/make-readme.py`, which refuses Built without a test in
the tree.

## The hero

The plan view and the lines under it replay
`packs/correlate-gnn/vectors/04-separation-dissolves.json` step by step: each
input's position, its reported error (`ce`) as a dashed circle, every trace
record and every expected event, in the order the vector lists them. Positions
are drawn to scale from latitude and longitude around the vector's reference
point. The page decides nothing; it shows what the vector says. With reduced
motion the view stops at step 3, where the group forms. Without JavaScript the
trace text of step 3 is shown.
