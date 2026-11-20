"""95 % bootstrap intervals for pooled measures, and the "better only when the intervals separate" rule.

A pooled measure is computed from counts summed over scenarios (score.add,
score.derive), so its interval resamples scenarios: draw as many scenarios as
the set holds, with replacement, sum their raw counts, derive the measure;
repeat B times; the interval is the 2.5th and 97.5th percentile of the B
values. The resampling uses the bench's own splitmix64 with a fixed seed, so
the same results give the same intervals everywhere.

Comparing two packs or two versions: a difference is "better" or "worse" only
when the two intervals do not overlap; otherwise "no difference shown".
"""

import score as scoring
from scenarios import Rng

B = 1000
SEED = 20261120
MEASURES = ["f1", "precision", "recall", "false_merges", "missed_merges", "swaps", "tta_s", "rms_m",
            "gospa_m"]
HIGHER_IS_BETTER = {"f1", "precision", "recall"}


def pooled(raws):
    tot = None
    for r in raws:
        tot = r if tot is None else scoring.add(tot, r)
    return scoring.derive(tot) if tot is not None else None


def interval(raws, b=B, seed=SEED):
    """{measure: [lo, hi]} over the bootstrap of the scenarios' raw counts (None when undefined)."""
    raws = list(raws)
    n = len(raws)
    if n == 0:
        return {}
    keys = sorted(raws[0])
    cols = {k: [r[k] for r in raws] for k in keys}
    rng = Rng(seed)
    vals = {m: [] for m in MEASURES}
    for _ in range(b):
        idx = [rng.integer(0, n - 1) for _ in range(n)]
        tot = {k: sum(cols[k][i] for i in idx) for k in keys}
        d = scoring.derive(tot)
        for m in MEASURES:
            if d.get(m) is not None:
                vals[m].append(d[m])
    out = {}
    for m, v in vals.items():
        if len(v) < b * 0.9:          # undefined in many resamples (for example no associations)
            out[m] = None
            continue
        v.sort()
        out[m] = [v[int(0.025 * (len(v) - 1))], v[int(0.975 * (len(v) - 1))]]
    return out


def summary(raws):
    """Pooled measures and their intervals for a list of raw counts."""
    raws = list(raws)
    return {"n": len(raws), "pooled": pooled(raws), "ci95": interval(raws)}


def verdict(measure, a_ci, b_ci):
    """Is B better than A on this measure? 'better', 'worse' or 'no difference shown'."""
    if not a_ci or not b_ci:
        return "no difference shown"
    if a_ci[1] < b_ci[0]:
        return "better" if measure in HIGHER_IS_BETTER else "worse"
    if b_ci[1] < a_ci[0]:
        return "worse" if measure in HIGHER_IS_BETTER else "better"
    return "no difference shown"
