# Fieldkit Processors: the runner's operator page

The page a person uses to watch and steer the runner: `processors.html`, one
file with no outside assets, built into the `goat-processors` binary and
served at `/ui`. What it shows and who may do what: [../README.md, "The
operator page"](../README.md#the-operator-page-fieldkit-processors).

It follows goatcore's Fieldkit rule (goatcore
`docs/design/fieldkit-and-bleating-edge.md`): the CLI and the API come first;
the page is a fixed list of at most eight actions over the same API, each
equal to a CLI verb, with no logic, state or authority of its own.

| Path | What | Status |
|---|---|---|
| `processors.html` | the page: eight actions, each declared once with `data-action`, `data-cli` (the verb) and `data-api` (the route) | Built |
| `bleating-edge/` | the Bleating Edge design system: tokens, components, `window.BE` ([README](bleating-edge/README.md)) | Copied from goatcore, three small changes |
| `inline.py` | writes `bleating-edge/` into the page between its markers; `--check` fails when the page's copy is stale | Built (from goatcore) |
| `check-scope.py` | the scope guard: every action is a row of `cli-allowlist.txt`, at most eight, no other network call; `--usage` checks every verb is in `goat-processors help` | Built (from goatcore) |
| `cli-allowlist.txt` | the actions the page may have: tool, verb, method, route | Written |
| `e2e/` | the browser test: Playwright drives every action against a running runner (`start.py` builds one with test certificates) | Built |

## Checks

Run from the repository root; CI (`.github/workflows/runner.yml`, job
`fieldkit`) runs each.

| Command | Checks |
|---|---|
| `python3 -I runner/fieldkit/inline.py --check` | the page carries the current `bleating-edge/` |
| `python3 -I runner/fieldkit/check-scope.py --self-test` | the guard refuses what it should |
| `runner/target/debug/goat-processors help > usage.txt && python3 -I runner/fieldkit/check-scope.py --usage usage.txt` | every action is allowed, and every allowed verb is a CLI command |
| `cd runner/fieldkit/e2e && npm ci && npx playwright install chromium && RUNNER_BIN=../../target/debug/goat-processors npx playwright test` | the page in a browser: as an operator over mutual TLS (all eight actions, each checked through the API) and as a local reader (changes off, and refused when forced) |

The browser test needs `openssl` and `python3`. Its one dependency,
`@playwright/test` (Apache-2.0), is pinned in `e2e/package-lock.json`; it is
test tooling, fetched in CI, and not part of the runner or its package.

## Changing the page

1. Edit `processors.html` (never the block between the Bleating Edge markers).
2. A new action needs a CLI verb and an API route first, then a row in
   `cli-allowlist.txt`. The page stays at eight actions or fewer.
3. Run `inline.py`, the checks above, and `cargo build`: the binary carries the
   page, so a change reaches a site with the next release.
