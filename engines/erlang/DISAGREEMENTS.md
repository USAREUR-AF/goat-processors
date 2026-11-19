# Disagreements

None. No vector contradicts specification 0.2.

## Points still open under 0.2

No vector exercises these. The engine resolves them as below.

| Point | Spec section | Engine behaviour |
|---|---|---|
| Whether a JSON number written with a fraction or exponent but integral value (`1000.0`, `1e3`) is an integer for `time_ms` or `stale_ms` | Reports | Not an integer: the JSON decoder yields a float, so the key is of the wrong type (missing for `time_ms`, absent for `stale_ms`) |
| Whether `same` treats an integer and a float of equal value (`1` and `1.0`) as equal | Tests (`same`) | Equal (numeric comparison); other values compare structurally |
| A `ce` of 0 or below | Reports, Track estimate | Used as given; no clamp or rejection |
