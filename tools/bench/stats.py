"""95 % bootstrap intervals for pooled measures, and the paired rule for "better".

A pooled measure is computed from counts summed over scenarios (score.add,
score.derive), so its interval resamples scenarios: draw as many scenarios as
the set holds, with replacement, sum their raw counts, derive the measure;
repeat B times; the interval is the 2.5th and 97.5th percentile of the B
values. The resampling uses the bench's own splitmix64 with a fixed seed, so
the same results give the same intervals everywhere.

Comparing two packs, or two versions of one: both ran on the same scenarios,
so the comparison is paired. Each resample draws one set of scenarios, the
measure is derived for both packs from that same draw, and the difference
(B minus A) is kept. B is "better" or "worse" only when the 95 % interval of
that difference excludes zero; otherwise "no difference shown". Pairing
removes the variation between scenarios that both packs share, so it detects
smaller real differences than comparing two separate intervals, and it is
the standard way to compare two methods on one benchmark (Efron and
Tibshirani, An Introduction to the Bootstrap, 1993, chapter 16).
"""

import score as scoring
from scenarios import Rng

B = 1000
SEED = 20261120
MEASURES = ["f1", "precision", "recall", "idf1", "completeness", "ambiguity", "spuriousness",
            "longest_segment", "track_changes_per_min", "false_merges", "missed_merges", "swaps", "tta_s",
            "rms_m", "siap_pa_m", "gospa_m"]
HIGHER_IS_BETTER = {"f1", "precision", "recall", "idf1", "completeness", "longest_segment"}
# Ambiguity is best at 1 (one track per object); a difference counts by distance from 1.
TOWARD_ONE = {"ambiguity"}


def pooled(raws, derive=scoring.derive):
    tot = None
    for r in raws:
        tot = dict(r) if tot is None else {k: tot.get(k, 0) + r[k] for k in r}
    return derive(tot) if tot is not None else None


def draws(n, b=B, seed=SEED):
    """The B resamples of n scenarios: the same for every pack, so any two can be paired."""
    rng = Rng(seed)
    return [[rng.integer(0, n - 1) for _ in range(n)] for _ in range(b)]


def resampled(raws, idx_sets, measures=MEASURES, derive=scoring.derive):
    """{measure: [value per resample, None where undefined]}."""
    raws = list(raws)
    keys = sorted(raws[0])
    cols = {k: [r[k] for r in raws] for k in keys}
    out = {m: [] for m in measures}
    for idx in idx_sets:
        d = derive({k: sum(cols[k][i] for i in idx) for k in keys})
        for m in measures:
            out[m].append(d.get(m))
    return out


def _pct(v, b):
    v = sorted(x for x in v if x is not None)
    if len(v) < b * 0.9:          # undefined in many resamples (for example no associations)
        return None
    return [v[int(0.025 * (len(v) - 1))], v[int(0.975 * (len(v) - 1))]]


def interval(raws, b=B, seed=SEED, measures=MEASURES, derive=scoring.derive):
    """{measure: [lo, hi]} over the bootstrap of the scenarios' raw counts (None when undefined)."""
    raws = list(raws)
    if not raws:
        return {}
    vals = resampled(raws, draws(len(raws), b, seed), measures, derive)
    return {m: _pct(v, b) for m, v in vals.items()}


def summary(raws):
    """Pooled measures and their intervals for a list of raw counts."""
    raws = list(raws)
    return {"n": len(raws), "pooled": pooled(raws), "ci95": interval(raws)}


def _gain(m, a, b):
    """How much better b is than a on measure m (positive is better)."""
    if m in TOWARD_ONE:
        return abs(a - 1.0) - abs(b - 1.0)
    return b - a if m in HIGHER_IS_BETTER else a - b


def paired(raws_a, raws_b, b=B, seed=SEED, measures=MEASURES, derive=scoring.derive):
    """{measure: [lo, hi]}: 95 % interval of how much better B is than A, positive is better.

    raws_a and raws_b are the two packs' raw counts on the same scenarios, in the same order."""
    raws_a, raws_b = list(raws_a), list(raws_b)
    if len(raws_a) != len(raws_b):
        raise ValueError("paired: the two lists must hold the same scenarios")
    if not raws_a:
        return {}
    idx = draws(len(raws_a), b, seed)
    va = resampled(raws_a, idx, measures, derive)
    vb = resampled(raws_b, idx, measures, derive)
    out = {}
    for m in measures:
        diffs = [_gain(m, x, y) if x is not None and y is not None else None for x, y in zip(va[m], vb[m])]
        out[m] = _pct(diffs, b)
    return out


def paired_from(values_a, values_b, m, b=B):
    """The same interval from two packs' per-resample values (made with the same draws)."""
    diffs = [_gain(m, x, y) if x is not None and y is not None else None for x, y in zip(values_a, values_b)]
    return _pct(diffs, b)


def verdict(gain_ci):
    """'better', 'worse' or 'no difference shown' from the interval of the gain (positive is better)."""
    if not gain_ci:
        return "no difference shown"
    if gain_ci[0] > 0:
        return "better"
    if gain_ci[1] < 0:
        return "worse"
    return "no difference shown"
