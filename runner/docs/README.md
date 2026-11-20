# Runner documents

| File | What | Status |
|---|---|---|
| `install-card.html` | the one-page install card for a person at the machine; the source of the PDF | Written |
| `install-card.pdf` | the card, US Letter, one page | Built from the HTML |

The card follows [INSTALL.md](../INSTALL.md); a change to the install steps
changes both. Its colors are the role tokens of the house visualization
system (light, dark and print), inline in the page; it needs no network.

## Build and gates

With the house visualization skill (`agent-workflow:visualization`) at `$VIZ`:

```sh
node $VIZ/scripts/figlint.mjs install-card.html        # light, dark, 900 and 680 px, print
python3 $VIZ/scripts/pdfgate.py build install-card.html -o install-card.pdf --pages 1 --size letter --body-pt 8.8
```

| Gate | Result |
|---|---|
| figlint | 0 errors, 0 warnings |
| pdfgate | 1 page, US Letter, 4 fonts, 0 Type 3 fonts, body text 8.8 pt |

## Critique log

| Round | Defect | Fix |
|---|---|---|
| 1 | 8 table cells ended with one word alone on a line | `text-wrap: pretty` on cells; three cells reworded |
| 1 | the PDF ran to two pages: the print rules for `main` had been left out, so the page kept its screen padding | print rules for `main`, headings, rows and the callout restored |
| 2 | one table row held two unrelated facts (where the tracks are; where the doctor fixes are) | split into two rows |
| 2 | spare space at the foot of the page | print type raised from 10.5 px to 11 px |
| 3 | the one-command line broke between `--ca` and its file: the callout paragraph was capped at 40em | the cap lifted inside the callout |
