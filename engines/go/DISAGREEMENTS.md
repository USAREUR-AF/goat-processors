# Disagreements and open points: Go engine

## Vectors that contradict the specification

None. Every vector in `packs/correlate-*/vectors/` (01-44) and
`spec/correlate-load-vectors/` (01-42) agrees with `spec/correlate.md` 0.5 and
`spec/correlate-assign.md` 0.3 as this engine reads them.

## Points still open

No vector covers any of them; each is listed with what this engine does.

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range | `correlate.md` Reports | not an integer: the field is treated as absent |
| `same` between booleans, arrays or objects | `correlate.md` Tests | booleans equal when both are the same boolean; arrays and objects equal when their JSON encodings (object keys sorted) are identical |
| A repeated parameter within one `filter`, `manoeuvre` or test line | `correlate.md` Pack | load error |
| Which decimal spellings a number may take | `correlate.md` Pack | Go `strconv.ParseFloat` / `ParseInt` base 10, minus hex, `inf`, `nan` and `_`; so `1e3`, `.5` and a leading `+` load, including `window +2` |
| Ranges of `confirm_count`, `hold_failures`, `stale_ms` and of test parameters | `correlate.md` Pack | any value that parses loads |
