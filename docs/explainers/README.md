# Explainer drawings

Status: Built. Two drawings that explain ideas rather than plot data, each in a
light and a dark variant for a `<picture>` element. Unlike `docs/figures/`,
nothing here is computed from the tree: each SVG is its own source and is
edited by hand. The example values in them (the costs 1, 9, 3 and 2, the clock
errors of 2, 80 and 400 ms, and the trace values 3.1 and 9.2) are
illustrations. The format count is goat-transformers' count when the drawing
was made; its README states the current one.

| Drawing | Shows | Used in |
|---|---|---|
| `correlation-steps` | the six steps of the default correlate method | [docs/how-correlation-works.md](../how-correlation-works.md), the site |
| `what-goat-adds` | the shared model, clock quality on every report, packs, traces and the fabric | [docs/what-is-different.md](../what-is-different.md), the site |

Each was checked rendered in a browser in both themes, at 900 and 680 px wide
and in print; colors come from one measured set of light and dark values.
