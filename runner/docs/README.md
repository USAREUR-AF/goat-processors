# Runner documents

| File | What | Status |
|---|---|---|
| `install-card.html` | the one-page install card for a person at the machine; the source of the PDF | Written |
| `install-card.pdf` | the card, US Letter, one page | Built from the HTML |
| `hardening-review.md` | the hardening review of the runner 0.4.0: what it exposes, twelve findings and their status, what was checked and found sound | Written; findings 1 to 6 Fixed, 9 and 10 Fixed in 0.6.0, 7 Open (next spec round) |

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
| 4 (cold read by proc-show) | `journalctl` without `sudo` shows nothing to a normal user | `sudo` on every `journalctl` |
| 4 | the card said four release files; the release has five | five, with `install-card.pdf` named |
| 4 | "edit the CHANGE-ME lines" led to replacing only part of the router address | "replace each word CHANGE-ME", keep `tls/` and the port; the placeholder is now `tls/CHANGE-ME:7447` |
| 4 | the private key's copy stayed in the home directory | step 5 ends with `rm runner.key` |
| 4 | two cells left one word alone at 680 px | reworded |
