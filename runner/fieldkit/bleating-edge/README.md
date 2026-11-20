# Bleating Edge (copy)

goat's design system for Fieldkit tools, copied from goatcore
`ops/fieldkit/bleating-edge/` at commit e6d72562 (goatcore PR 1101, on the
branch `integration/adr-1251`). Same license (Apache-2.0) and the same
copyright holder as this repository. Its documentation is goatcore's
`ops/fieldkit/bleating-edge/README.md`.

| File | What |
|---|---|
| `bleating-edge.css` | tokens and the eight components; unchanged but for one comment in American spelling |
| `bleating-edge.js` | `window.BE`; three changes, below |

The changes keep goatcore's behavior when not used, and are offered back to
goatcore:

| Change | Why |
|---|---|
| `BE.program` (default `goat`): the command the "Same as" strip and the confirm sheet print | the runner's CLI is `goat-processors` |
| `BE.thing` (default `pod`): the word for the service in the "did not answer" and "refused" texts | the page talks to a runner, not a pod |
| `BE.call` also reads an error body `{"error": text, "fix": text}` | the runner's API answers errors in that shape (`runner/openapi.yaml`); the page shows the runner's own words and fix |

Edit these files, then run `python3 -I runner/fieldkit/inline.py`.
