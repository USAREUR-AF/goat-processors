"""Write docs/benchmark.md, the per-scenario CSV and the SVG figures under docs/figures/bench/
from results.json.

Every number in the documents comes from results.json; nothing is written by hand.
"""

import csv
import io
import math
import os

import adapters

ROOT = adapters.ROOT
DOC = os.path.join(ROOT, "docs", "benchmark.md")
FIG = os.path.join(ROOT, "docs", "figures", "bench")
CSV = os.path.join(FIG, "per-scenario.csv")
DEFAULT = "correlate-assign-time"       # the pack the runner ships (runner/config/runner.yaml)
REPO = "https://github.com/USAREUR-AF/goat-processors"

# Categorical slots in fixed order (one per pack, never cycled), light and dark.
SERIES = {
    "light": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"],
    "dark": ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#0ca30c", "#9085e9", "#e66767"],
}
# The scenario figure: one colour per sensor, cool hues only.
SENSOR_INK = {"light": {"radar": "#2a78d6", "beacon": "#0f8a5f", "passive": "#6b7280"},
              "dark": {"radar": "#5b9cf0", "beacon": "#2fbf8a", "passive": "#a3a8b3"}}

# Packs left out of the summary chart (eight slots at most), with the reason; they stay in every table.
CHART_OMIT = {"correlate-assign-window": "assign-full includes its multi-frame window",
              "correlate-assign-bias": "assign-full includes its bias estimate",
              "correlate-assign-full": "assign-time is assign-full plus a fitted clock offset",
              "correlate-gnn-time": "it differs from gnn only on the time scenarios"}
INK = {
    "light": dict(surface="#fcfcfb", text="#0b0b0b", text2="#52514e", muted="#898781",
                  grid="#e1e0d9", axis="#c3c2b7"),
    "dark": dict(surface="#1a1a19", text="#f0efec", text2="#c3c2b7", muted="#898781",
                 grid="#2c2c2a", axis="#383835"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

# (key, label, format, higher is better); None: best at 1
ASSOC = [("f1", "Pairwise F1", "{:.3f}", True), ("precision", "Precision", "{:.3f}", True),
         ("recall", "Recall", "{:.3f}", True), ("false_merges", "False merges", "{:d}", False),
         ("missed_merges", "Missed merges", "{:d}", False), ("swaps", "Identity swaps", "{:d}", False),
         ("tta_s", "Time to associate, s", "{:.1f}", False)]
PICTURE = [("idf1", "IDF1", "{:.3f}", True), ("completeness", "Completeness", "{:.3f}", True),
           ("ambiguity", "Ambiguity", "{:.3f}", None), ("spuriousness", "Spuriousness", "{:.3f}", False),
           ("longest_segment", "Longest segment", "{:.3f}", True),
           ("track_changes_per_min", "Track changes per min", "{:.2f}", False),
           ("siap_pa_m", "Position accuracy, m", "{:.1f}", False), ("gospa_m", "GOSPA, m", "{:.1f}", False)]
ALL = {k: (lab, f, hi) for k, lab, f, hi in ASSOC + PICTURE}
HEAD = ["f1", "idf1", "completeness", "spuriousness", "longest_segment", "gospa_m"]
CSV_MEASURES = ["f1", "precision", "recall", "idf1", "completeness", "ambiguity", "spuriousness",
                "longest_segment", "track_changes_per_min", "false_merges", "missed_merges", "swaps",
                "tta_s", "siap_pa_m", "gospa_m"]
SCENE = "crossing-20deg"         # the named scenario drawn in "What a scenario looks like"
SCENE_HALF_S = 30                # seconds either side of the closest approach


def fmt(v, f):
    if v is None:
        return "–"
    if f == "{:d}":
        return str(int(v))
    return f.format(v)


def short(pack):
    return pack[len("correlate-"):] if pack.startswith("correlate-") else pack


def plink(pack, baselines=()):
    """A pack name in a table, linked to its description."""
    if pack in baselines:
        return "[%s](#outside-baseline) (outside baseline)" % short(pack)
    return "[%s](../README.md#methods-and-packs)" % short(pack)


def gain_of(paired_group, a, b, m):
    """Interval of how much better b is than a (bench.gain_of, without importing bench here)."""
    if not paired_group:
        return None
    g = paired_group["gain"]
    if b in g and a in g[b]:
        return g[b][a].get(m)
    if a in g and b in g[a]:
        ci = g[a][b].get(m)
        return [-ci[1], -ci[0]] if ci else None
    return None


def verdict(ci):
    if not ci:
        return "no difference shown"
    return "better" if ci[0] > 0 else "worse" if ci[1] < 0 else "no difference shown"


# ---------------------------------------------------------------------------
# SVG


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def nice_max(v):
    if v <= 0:
        return 1.0
    for m in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        step = m * 10 ** (len(str(int(v))) - 1) if v >= 1 else m
        if step >= v:
            return float(step)
    return float(10 ** len(str(int(v))))


def panels(title, subtitle, packs, items, mode):
    """Small multiples: one panel per measure, one bar per pack, each panel its own scale."""
    ink, cols = INK[mode], SERIES[mode] + ["#7a7a7a"]
    pw, gapx, top0, per_row = 230, 24, 70, 3
    bar, gap = 14, 6
    ph = len(packs) * (bar + gap) + 44
    nrow = (len(items) + per_row - 1) // per_row
    w = 16 + per_row * (pw + gapx)
    h = top0 + nrow * ph + 6
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="%s" role="img" aria-label="%s">' % (w, h, w, h, FONT, esc(title)),
         '<rect width="100%%" height="100%%" fill="%s"/>' % ink["surface"],
         '<text x="16" y="26" font-size="15" font-weight="600" fill="%s">%s</text>' % (ink["text"], esc(title)),
         '<text x="16" y="45" font-size="12" fill="%s">%s</text>' % (ink["text2"], esc(subtitle))]
    for k, (label, vals, f, higher) in enumerate(items):
        x0 = 16 + (k % per_row) * (pw + gapx)
        top = top0 + (k // per_row) * ph
        o.append('<text x="%d" y="%d" font-size="12" font-weight="600" fill="%s">%s</text>'
                 % (x0, top, ink["text"], esc(label)))
        o.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>'
                 % (x0, top + 14, ink["muted"], "higher is better" if higher else "lower is better"))
        present = [v for v in vals if v is not None]
        vmax = nice_max(max(present)) if present else 1.0
        lab_w = max(62, int(6.2 * max(len(short(p)) for p in packs)) + 8)
        for i, p in enumerate(packs):
            y = top + 24 + i * (bar + gap)
            o.append('<text x="%d" y="%d" font-size="11" fill="%s">%s</text>'
                     % (x0, y + bar - 3, ink["text2"], esc(short(p))))
            v = vals[i]
            if v is None:
                continue
            bw = max((pw - lab_w - 40) * v / vmax, 1.0)
            o.append('<rect x="%d" y="%d" width="%.1f" height="%d" rx="2" fill="%s"><title>%s %s: %s</title></rect>'
                     % (x0 + lab_w, y, bw, bar, cols[min(i, len(cols) - 1)], esc(short(p)), esc(label),
                        esc(fmt(v, f))))
            o.append('<text x="%.1f" y="%d" font-size="11" fill="%s">%s</text>'
                     % (x0 + lab_w + bw + 4, y + bar - 3, ink["text"], esc(fmt(v, f))))
    o.append("</svg>")
    return "\n".join(o) + "\n"


def scene(mode):
    """One named scenario drawn: true paths, and every report each sensor made."""
    import scenarios as S
    sc = next(s for s in S.named() if s.name == SCENE)
    vector, truth = sc.build()
    ink, sink = INK[mode], SENSOR_INK[mode]
    # the window of SCENE_HALF_S either side of the objects' closest approach
    objs = sorted(truth["objects"])
    sep = []
    for i, t in enumerate(truth["ticks"]):
        ps = [truth["objects"][o]["pos"][i] for o in objs[:2]]
        if all(ps):
            (ax, ay), (bx, by) = (S.to_plane(*p) for p in ps)
            sep.append((math.hypot(ax - bx, ay - by), t))
    t_c = min(sep)[1]
    lo, hi = t_c - SCENE_HALF_S * 1000, t_c + SCENE_HALF_S * 1000
    pts = []
    for st in vector["steps"]:
        if "ingest" in st and lo <= st["ingest"]["time_ms"] <= hi:
            r = st["ingest"]
            pts.append((r["track.source_id"],) + S.to_plane(r["lat"], r["lon"]))
    paths = {o: [S.to_plane(*p) for t, p in zip(truth["ticks"], d["pos"]) if p and lo <= t <= hi]
             for o, d in truth["objects"].items()}
    # turn the picture so the aircraft fly left to right (north stays meaningless here: the
    # scale bar is the only reference the reader needs)
    hx = sum(v[-1][0] - v[0][0] for v in paths.values() if v)
    hy = sum(v[-1][1] - v[0][1] for v in paths.values() if v)
    ang = -math.atan2(hy, hx)
    ca, sa = math.cos(ang), math.sin(ang)
    rot = lambda x, y: (x * ca - y * sa, x * sa + y * ca)                       # noqa: E731
    pts = [(src,) + rot(x, y) for src, x, y in pts]
    paths = {o: [rot(x, y) for x, y in v] for o, v in paths.items()}
    xs = [p[1] for p in pts] + [x for v in paths.values() for x, _ in v]
    ys = [p[2] for p in pts] + [y for v in paths.values() for _, y in v]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h, pad, top = 760, 300, 28, 64
    span = max(x1 - x0, (y1 - y0) * (w - 2 * pad) / (h - top - pad - 40))
    k = (w - 2 * pad) / span
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    X = lambda x: w / 2 + (x - cx) * k                       # noqa: E731
    Y = lambda y: top + (h - top - 40) / 2 - (y - cy) * k     # noqa: E731
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="%s" role="img" aria-label="%s">' % (w, h, w, h, FONT, esc(
             "Scenario %s: two aircraft crossing, each reported by a radar and a beacon" % SCENE)),
         '<rect width="100%%" height="100%%" fill="%s"/>' % ink["surface"],
         '<text x="16" y="26" font-size="15" font-weight="600" fill="%s">%s</text>'
         % (ink["text"], esc("Scenario %s: what the correlator sees, and the truth it is scored against" % SCENE)),
         '<text x="16" y="45" font-size="12" fill="%s">%s</text>'
         % (ink["text2"], esc("%d s around the closest approach. Dots: every report of each sensor. Grey lines: "
                              "the true paths, never shown to the correlator." % (2 * SCENE_HALF_S)))]
    for o_id, v in sorted(paths.items()):
        d = " ".join("%s%.1f,%.1f" % ("M" if i == 0 else "L", X(x), Y(y)) for i, (x, y) in enumerate(v))
        o.append('<path d="%s" fill="none" stroke="%s" stroke-width="2.5" stroke-linecap="round"/>'
                 % (d, ink["axis"]))
        ex, ey = v[-1]
        o.append('<text x="%.1f" y="%.1f" font-size="12" text-anchor="end" fill="%s">%s</text>'
                 % (X(ex), Y(ey) + (18 if ey < cy else -10), ink["text2"], esc("aircraft " + o_id[1:])))
    rad = {"radar": 4.0, "beacon": 2.6, "passive": 3.2}
    for src, x, y in pts:
        o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s" fill-opacity="0.75"/>'
                 % (X(x), Y(y), rad.get(src, 2.0), sink.get(src, ink["muted"])))
    lx = 16
    sens = {s.split(" ")[0]: s for s in truth["sensors"]}
    for src in ("radar", "beacon", "passive"):
        if src not in sens:
            continue
        o.append('<circle cx="%d" cy="%d" r="5" fill="%s"/>' % (lx + 5, h - 18, sink[src]))
        o.append('<text x="%d" y="%d" font-size="12" fill="%s">%s</text>'
                 % (lx + 14, h - 14, ink["text2"], esc(sens[src].split(",")[0] + ", " + sens[src].split(",")[1].strip())))
        lx += 250
    bar_m = nice_max(span / 5.0)
    bx = w - pad - bar_m * k
    o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" stroke-width="2"/>'
             % (bx, h - 36, w - pad, h - 36, ink["text2"]))
    o.append('<text x="%.1f" y="%d" font-size="11" text-anchor="end" fill="%s">%s</text>'
             % (w - pad, h - 42, ink["text2"], esc("%g km" % (bar_m / 1000.0))))
    o.append("</svg>")
    return "\n".join(o) + "\n"


# ---------------------------------------------------------------------------
# Markdown


def picture(name, alt):
    return ('<picture>\n'
            '  <source media="(prefers-color-scheme: dark)" srcset="figures/bench/%s-dark.svg">\n'
            '  <img alt="%s" src="figures/bench/%s-light.svg">\n'
            '</picture>\n' % (name, esc(alt), name))


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    for r in rows:
        out.append("| " + " | ".join(c.replace("|", "\\|") for c in r) + " |")
    return "\n".join(out) + "\n"


MIN_CI_N = 5   # below this many scenarios a bootstrap interval says nothing; the count is shown instead


def ci_cell(summ, key, f):
    """'value (lo to hi)' for a pooled measure with its 95 % interval."""
    if not summ or not summ.get("pooled"):
        return "–"
    v = summ["pooled"].get(key)
    if v is None:
        return "–"
    ci = (summ.get("ci95") or {}).get(key)
    if summ.get("n", 0) < MIN_CI_N:
        return "%s (%d scenario%s, no interval)" % (fmt(v, f), summ["n"], "" if summ["n"] == 1 else "s")
    lo_f = f if f != "{:d}" else "{:.0f}"
    return fmt(v, f) if not ci else "%s (%s to %s)" % (fmt(v, f), fmt(ci[0], lo_f), fmt(ci[1], lo_f))


def val(groups, pack, grp, key):
    s = (groups.get(pack) or {}).get(grp) or {}
    return (s.get("pooled") or {}).get(key)


COMPARED = ("f1", "idf1", "completeness", "ambiguity", "spuriousness", "longest_segment", "false_merges",
            "missed_merges", "swaps", "gospa_m")


def counts(paired, a, b):
    """'n better, m worse': b against a over the compared measures, by the paired test."""
    if not paired:
        return "–"
    v = [verdict(gain_of(paired, a, b, m)) for m in COMPARED]
    better, worse = v.count("better"), v.count("worse")
    if not better and not worse:
        return "no difference shown"
    return ", ".join(x for x in ("%d better" % better if better else "", "%d worse" % worse if worse else "") if x)


def against_default(paired, pack):
    return "the default" if pack == DEFAULT else counts(paired, DEFAULT, pack)


def best_or_equal(groups, paired, packs, grp, key, higher):
    """The packs whose value on key is the best, or not shown worse than the best by the paired rule."""
    scored = [p for p in packs if val(groups, p, grp, key) is not None]
    if not scored:
        return set()
    if higher is None:
        best = min(scored, key=lambda p: abs(val(groups, p, grp, key) - 1.0))
    else:
        best = (max if higher else min)(scored, key=lambda p: val(groups, p, grp, key))
    out = {best}
    for p in scored:
        if p != best and verdict(gain_of(paired, best, p, key)) != "worse":
            out.add(p)
    return out


def headline_rows(groups, paired, packs, baselines, grp="random"):
    order = sorted(packs + baselines, key=lambda p: -(val(groups, p, grp, "f1") or 0))
    rows = []
    bold = {k: best_or_equal(groups, paired, packs + baselines, grp, k, ALL[k][2]) for k in HEAD}
    for p in order:
        s = groups[p].get(grp)
        cells = []
        for k in HEAD:
            lab, f, hi = ALL[k]
            c = ci_cell(s, k, f) if k == "f1" else fmt(val(groups, p, grp, k), f)
            cells.append("**%s**" % c if p in bold[k] else c)
        name = "**%s**" % plink(p, baselines) if p == DEFAULT else plink(p, baselines)
        rows.append([name] + cells + [against_default(paired, p)])
    return rows


def headline_sentence(groups, paired, packs, baselines, n, setname):
    d = groups[DEFAULT]["random"]
    f1 = ci_cell(d, "f1", "{:.3f}")
    scored = [p for p in packs if val(groups, p, "random", "f1") is not None]
    top = max(scored, key=lambda p: val(groups, p, "random", "f1"))
    if top == DEFAULT:
        rank = "the highest of the %d packs" % len(packs)
    elif verdict(gain_of(paired, top, DEFAULT, "f1")) == "worse":
        rank = "below `%s` (%.3f)" % (short(top), val(groups, top, "random", "f1"))
    else:
        rank = "level with the highest, `%s` (%.3f): the paired interval of their difference includes zero" % (
            short(top), val(groups, top, "random", "f1"))
    s = ("On the %d random scenarios of the %s set, the default pack `%s` scores pairwise F1 %s, %s. "
         "Its IDF1 is %.3f and its GOSPA %.0f m." % (n, setname, short(DEFAULT), f1, rank,
                                                     val(groups, DEFAULT, "random", "idf1") or 0,
                                                     val(groups, DEFAULT, "random", "gospa_m") or 0))
    for b in baselines:
        if val(groups, b, "random", "f1") is not None:
            s += (" The outside baseline, a Stone Soup tracker, scores F1 %.3f and IDF1 %.3f; against it the "
                  "default is %s of the ten compared measures." % (
                      val(groups, b, "random", "f1"), val(groups, b, "random", "idf1") or 0, counts(paired, b, DEFAULT)))
    return s


def family_table(groups, paired, packs, baselines, key):
    lab, f, hi = ALL[key]
    allp = packs + baselines
    fams = sorted(g for g in groups[packs[0]] if g.startswith("family: "))
    bold = {g: best_or_equal(groups, (paired or {}).get(g), allp, g, key, hi) for g in fams}
    rows = []
    for p in allp:
        row = [plink(p, baselines)]
        for g in fams:
            c = groups[p].get(g) or {}
            cell = fmt(val(groups, p, g, key), f)
            if c.get("not_finished"):
                cell += " (%d not finished)" % c["not_finished"]
            row.append("**%s**" % cell if p in bold[g] else cell)
        rows.append(row)
    counts = {g: groups[packs[0]][g]["n"] + groups[packs[0]][g]["not_finished"] for g in fams}
    return table(["Pack"] + ["%s (%d)" % (g[len("family: "):], counts[g]) for g in fams], rows)


def full_tables(L, groups, packs, baselines, grp, what):
    for title, ms in (("Association", ASSOC), ("Picture", PICTURE)):
        L.append("**%s, %s**\n" % (title, what))
        L.append(table(["Pack"] + [lab for _, lab, _, _ in ms],
                       [[plink(p, baselines)] + [ci_cell(groups[p].get(grp), k, f) for k, _, f, _ in ms]
                        for p in packs + baselines]))


def per_scenario_csv(res):
    out = io.StringIO()
    w = csv.writer(out, lineterminator="\n")
    w.writerow(["scenario", "family", "pack"] + CSV_MEASURES)
    import score as scoring
    raws = dict(res["raw"], **(res.get("baseline_raw") or {}))
    for m in res["meta"]:
        for p in res["packs"] + res.get("baselines", []):
            r = raws.get(p, {}).get(m["name"])
            if r is None:
                w.writerow([m["name"], m["family"], short(p)] + ["not finished"] + [""] * (len(CSV_MEASURES) - 1))
                continue
            d = scoring.derive(r)
            w.writerow([m["name"], m["family"], short(p)] + [
                "" if d.get(k) is None else (str(d[k]) if isinstance(d[k], int) else "%.6g" % d[k])
                for k in CSV_MEASURES])
    return out.getvalue()


def render_all(res):
    """Every generated file: {path: text}."""
    packs = res["packs"]
    baselines = res.get("baselines", [])
    cpacks = [p for p in packs if p not in CHART_OMIT]
    if len(cpacks) > len(SERIES["light"]):
        raise SystemExit("more than %d packs to chart: add one to CHART_OMIT" % len(SERIES["light"]))
    import bench as _b
    legacy = _b.named_names()
    named = [m for m in res["meta"] if m["name"] in legacy]
    timed = [m for m in named if m["family"] == "time"]
    tu = res.get("tuning", {})
    ev = res.get("evaluation")
    evb = [b for b in baselines if ev and b in ev["groups"]]
    files = {}

    # figures
    if ev:
        G, P, setname, chart_b = ev["groups"], ev.get("paired", {}), "evaluation", evb
    else:
        G, P, setname, chart_b = tu["groups"], tu.get("paired", {}), "tuning", baselines
    n_random = G[packs[0]]["random"]["n"]
    chart_packs = cpacks + chart_b
    summary = [(ALL[k][0], [val(G, p, "random", k) for p in chart_packs], ALL[k][1], ALL[k][2])
               for k in ("f1", "idf1", "spuriousness", "longest_segment", "swaps", "gospa_m")]
    for mode in ("light", "dark"):
        files[os.path.join(FIG, "random-%s.svg" % mode)] = panels(
            "%s set: %d random scenarios pooled" % (setname.capitalize(), n_random),
            "each panel has its own scale", chart_packs, summary, mode)
        files[os.path.join(FIG, "scene-%s.svg" % mode)] = scene(mode)
    files[CSV] = per_scenario_csv(res)

    L = []
    L.append("# Correlation benchmark\n")
    L.append("Status: Measured. Generated by `python3 -I tools/bench/bench.py report`; do not edit by hand. "
             "Every formula: [tools/bench/README.md](../tools/bench/README.md#scores).\n")
    L.append("Several sensors each report their own tracks of the same aircraft, vessels and vehicles. The "
             "correlate function decides which of those tracks belong to the same object and gives one "
             "system track per object. This page measures how well each correlate pack does that, on "
             "scenarios where the true answer is known, and sets the packs against an outside tracker.\n")

    # Results
    L.append("## Results\n")
    L.append(headline_sentence(G, P.get("random"), packs, chart_b, n_random, setname) + "\n")
    L.append("%s set, %d random scenarios. Packs in order of pairwise F1. **Bold**: the best value of the "
             "column, and every value not shown worse than it by the paired test below. *Against the "
             "default* counts the ten compared measures (F1, IDF1, completeness, ambiguity, spuriousness, "
             "longest segment, false merges, missed merges, identity swaps, GOSPA) on which the pack is "
             "better or worse than `%s`.\n" % (setname.capitalize(), n_random, short(DEFAULT)))
    L.append(table(["Pack", "Pairwise F1 (95 % interval)", "IDF1", "Completeness", "Spuriousness",
                    "Longest segment", "GOSPA, m", "Against the default"],
                   headline_rows(G, P.get("random"), packs, chart_b)))
    L.append(picture("random", "Six measures over the %s random set, one bar per pack" % setname))
    omitted = [p for p in packs if p in CHART_OMIT]
    if omitted:
        L.append("The chart leaves out %s; the tables include every pack.\n" % "; ".join(
            "%s (%s)" % (short(p), CHART_OMIT[p]) for p in omitted))
    L.append("Higher is better for F1, IDF1, completeness and longest segment; lower for spuriousness and "
             "GOSPA. What each measure asks is in [What is measured](#what-is-measured). Per family: "
             "[Results by family](#results-by-family). Every measure with its interval: "
             "[Full tables](#full-tables). Every scenario and pack: "
             "[per-scenario.csv](figures/bench/per-scenario.csv) (tuning set).\n")

    # Scenario
    L.append("## What a scenario looks like\n")
    L.append(picture("scene", "Scenario %s: the true paths of three objects and every report of a radar, "
                     "a beacon and a passive sensor" % SCENE))
    L.append("A scenario is a few minutes of input. Objects move on true paths: still, straight, turning, "
             "accelerating, in formation, crossing, or recorded ship motion. Each sensor reports its own "
             "track of each object it sees, with its own track number, at its own rate, with random "
             "position error and, usually, a stated error (`ce`, one standard deviation in meters). The "
             "correlator sees only the reports, in the order they arrive. Once a second it gives its "
             "picture: each system track and the sensor tracks it holds. Truth is used only to score that "
             "picture.\n")
    L.append("Sensors, unless a scenario changes them:\n")
    L.append(table(["Sensor", "Report every", "Position error (1 sigma)", "Detection probability",
                    "Latency", "Velocity", "Height"],
                   [["radar", "4 s (0.2 s jitter)", "60 m", "0.9", "0.5 s", "yes, 5 m/s", "yes"],
                    ["beacon", "1 s (0.1 s jitter)", "15 m", "0.98", "0.3 s", "yes, 1 m/s", "yes"],
                    ["passive", "2 s (0.3 s jitter)", "250 m", "0.8", "1 s", "no", "no"]]))
    L.append("The random generator places 2 to 4 objects (still, straight, turning or accelerating) and 2 or "
             "3 sensors. Each sensor, independently, may state its error too small or not at all (25 %), "
             "carry a fixed bias of up to 300 m (20 %), arrive 1 to 3 s late (20 %), detect only 50 to 90 % "
             "of the time (20 %), swap two objects' track numbers (20 %), drop and renumber a track (20 %), "
             "and report 1 to 5 false tracks (20 %). The families each test one kind of difficulty:\n")
    fam_rows = [["formation", "2 to 8 aircraft 200 to 1,000 m apart behind a turning leader; members hold, split away or join"],
                ["crossing", "2 to 4 objects whose paths meet at 3 to 25 degrees; half then fly on together"],
                ["maneuver", "turns at 3 to 9 g, climbs and dives, surface traffic that stops and starts"],
                ["sensor problems", "two or three of: dropouts, intermittent updates, long latency, out-of-order "
                 "delivery, wrong stated error, biases, clock drift"],
                ["clutter", "0 to 40 false tracks on the radar, half as many on the passive sensor"],
                ["mixed domains", "surface vessels, a low slow helicopter, land vehicles and an aircraft together"],
                ["track management", "dropped tracks with and without number reuse, number swaps, sensors joining late"],
                ["recorded ships", "30 minutes of real ship motion from public AIS data, with simulated sensors"]]
    L.append(table(["Family", "What it tests"], fam_rows))
    L.append("The 21 named scenarios each test one thing, and 7 more test clocks; they are listed in "
             "[Named scenarios](#named-scenarios). Every generator and its settings: "
             "[tools/bench/README.md](../tools/bench/README.md).\n")

    # Sets
    L.append("## The two sets\n")
    L.append(table(["Set", "Content", "Seeds", "Use"], [
        ["evaluation", "%s; names start `eval-`" % (
            "%d scenarios: 500 random and the evaluation half of every family" % ev["scenarios"] if ev
            else "500 random scenarios and the evaluation half of every family"),
         "private, held by the benchmark maintainer; published after each release, then replaced%s" % (
             " (this run: rotation %d)" % ev["rotation"] if ev and ev.get("rotation") else ""),
         "**the numbers in Results, the README and the site**; never used to tune a pack"],
        ["tuning", "%d scenarios: the 28 named, 500 random (the first 50 are the earlier random set) and the "
         "tuning half of every family" % len(res["meta"]), "public (`tools/bench/dataset.py`)",
         "developing and tuning packs; review records; CI re-runs a subset"]]))
    L.append("Keeping the evaluation seeds private means no pack can be tuned to the scenarios it is judged "
             "on, as public tracking benchmarks hold back their test sets. Publishing them after each release "
             "lets anyone check the numbers that were reported.\n")

    # Measures
    L.append("## What is measured\n")
    L.append("Each measure answers one question about the picture the correlator gives. The first two are "
             "about grouping and identity, the next five are the air-picture measures of the Single "
             "Integrated Air Picture (SIAP) program, and GOSPA is about position.\n")
    L.append(table(["Measure", "The question", "Best", "Source"], [
        ["Pairwise F1", "Are two live sensor tracks in one system track exactly when they are the same object? "
         "Every pair of tracks, every second; F1 combines precision (no wrong pairs) and recall (no missed pairs)",
         "1", "the pairwise F1 of clustering and record linkage; correlation is a grouping of tracks"],
        ["IDF1", "Does each object keep one system track for its life? The share of object-seconds covered by "
         "the system track matched to that object over the whole scenario", "1",
         "Ristani et al., *Performance Measures and a Data Set for Multi-Target, Multi-Camera Tracking*, "
         "ECCV 2016"],
        ["Completeness", "What share of the time is each object covered by some system track?", "1", "SIAP"],
        ["Ambiguity", "How many system tracks are there per covered object? Above 1 is duplicates", "1", "SIAP"],
        ["Spuriousness", "What share of system tracks are on no object?", "0", "SIAP"],
        ["Longest segment", "The longest stretch an object is followed by one system track, as a share of its "
         "life", "1", "SIAP"],
        ["Track changes per min", "How often does the system track following an object change?", "0", "SIAP"],
        ["GOSPA", "Position: the distance between the system tracks and the objects, each error capped at "
         "500 m, each missed or false track charged half the cap", "0",
         "Rahmathullah, García-Fernández and Svensson, *Generalized optimal sub-pattern assignment metric*, "
         "FUSION 2017"],
    ]))
    L.append("A system track is *on* an object when it is within 500 m of it (the GOSPA cut-off); IDF1 and "
             "the SIAP measures use that test. The SIAP measures are those defined by the SIAP Systems "
             "Engineering Task Force (2001), the set Stone Soup's `SIAPMetrics` also computes; here an object "
             "keeps the system track that follows it while that track stays within 500 m, and every formula "
             "is in tools/bench/README.md. This benchmark's own counts "
             "complete the picture: a **false merge** puts tracks of two objects together, a **missed merge** "
             "keeps one object's tracks apart for 10 s or more, an **identity swap** moves an object to "
             "another system track while the old one still exists, and **time to associate** is how long two "
             "tracks of one object wait before they are grouped.\n")

    # Better
    L.append("## How \"better\" is decided\n")
    L.append("Every pack runs on the same scenarios, so two packs are compared scenario by scenario. The "
             "test is a paired bootstrap: draw as many scenarios as the group holds, with replacement; "
             "compute the measure for both packs on that same draw; keep the difference; repeat 1,000 times. "
             "One pack is **better** or **worse** than another only when the 95 %% interval of the difference "
             "excludes zero; otherwise no difference is shown (Efron and Tibshirani, *An Introduction to the "
             "Bootstrap*, 1993, chapter 16). Pairing removes the variation between scenarios that both packs "
             "share, so it finds smaller real differences than comparing two separate intervals. The interval "
             "beside a single value is the same bootstrap for that pack alone: how far the value would move "
             "on another draw of scenarios like these. A pooled measure sums the counts of every scenario of "
             "a group and then divides. A run over %d s on one scenario is reported as not finished and left "
             "out of its group.\n" % tu.get("timeout_s", 300))

    # Reproduce
    L.append("## Reproduce\n")
    L.append("Python 3.12 and a clone; nothing to install for the packs.\n")
    L.append("```sh\n"
             "git clone %s && cd goat-processors\n"
             "python3 -I tools/bench/bench.py check      # a subset; confirms the committed numbers (minutes)\n"
             "python3 -I tools/bench/bench.py report     # every pack on the tuning set\n"
             "python3 -I tools/bench/bench.py diff docs/figures/bench/results.json mine.json --set tuning\n"
             "\n"
             "# the outside baseline\n"
             "python3 -m venv .venv && .venv/bin/pip install -r tools/baselines/requirements.txt\n"
             ".venv/bin/python -I tools/bench/bench.py report --baselines\n"
             "```\n" % REPO)
    if tu.get("seconds"):
        L.append("The tuning set took %d min in %d processes on the benchmark machine%s. `report` writes "
                 "`docs/figures/bench/results.json` and this page; `diff` compares two results files with the "
                 "paired test. The evaluation set needs the private seeds: the maintainer runs it, and "
                 "anyone can run it once the seeds are published. To score your own tracker on the same "
                 "scenarios, see [Compare your tracker](../reviews/README.md#compare-your-tracker).\n"
                 % (round(tu["seconds"] / 60.0), tu["jobs"],
                    "; the evaluation set %d min" % round(ev["seconds"] / 60.0) if ev else ""))

    # Baseline
    L.append("## Outside baseline\n")
    L.append("Stone Soup is the open tracking framework of the UK Defence Science and Technology Laboratory "
             "([github.com/dstl/Stone-Soup](https://github.com/dstl/Stone-Soup)). `stonesoup-gnn` "
             "([tools/baselines/stonesoup_gnn.py](../tools/baselines/stonesoup_gnn.py), Stone Soup 1.9.1) is "
             "the textbook tracker built from its components: every report of every sensor is one detection; "
             "a constant-velocity Kalman filter per track, with the report's own stated error; a 99.9 %% "
             "Mahalanobis gate; global nearest-neighbor assignment; a new track from each report that fits no "
             "track; deletion after 20 s without a report. A sensor track belongs to the Stone Soup track that "
             "took its latest report, and that grouping is scored like any pack's. Tracking every report "
             "centrally is the classic alternative to correlating the sensors' tracks, so a correlator should "
             "beat it on these scenarios. It has none of the packs' options (bias and clock offsets, a "
             "two-model filter, a multi-frame window). Its speed is not what is measured, so its time limit is "
             "%d times the packs'. Its two settings, the motion noise and the gate, were chosen on the tuning set, as "
             "the packs' were.\n" % _b.BASELINE_TIMEOUT_FACTOR)
    if not chart_b:
        L.append("Not run on this tree: `bench.py report --baselines`.\n")

    # Families
    L.append("## Results by family\n")
    L.append("%s set; values pooled over each family. **Bold**: the best, and every pack not shown worse "
             "than it by the paired test.\n" % setname.capitalize())
    for key in ("f1", "idf1", "gospa_m"):
        L.append("**%s**\n" % ALL[key][0])
        L.append(family_table(G, P, packs, chart_b, key))

    # Full tables
    L.append("## Full tables\n")
    L.append("Every measure with its 95 % interval, on the random scenarios of each set.\n")
    if ev:
        full_tables(L, ev["groups"], packs, evb, "random", "evaluation set, %d random scenarios" % n_random)
    if tu.get("groups"):
        full_tables(L, tu["groups"], packs, baselines, "random",
                    "tuning set, %d random scenarios" % tu["groups"][packs[0]]["random"]["n"])
        L.append("**Named scenarios and time scenarios, tuning set, pooled**\n")
        L.append(table(["Pack", "Group", "Pairwise F1", "IDF1", "Identity swaps", "GOSPA, m"],
                       [[plink(p, baselines), g, ci_cell(tu["groups"][p].get(g), "f1", "{:.3f}"),
                         ci_cell(tu["groups"][p].get(g), "idf1", "{:.3f}"),
                         ci_cell(tu["groups"][p].get(g), "swaps", "{:d}"),
                         ci_cell(tu["groups"][p].get(g), "gospa_m", "{:.1f}")]
                        for g in ("named", "time") for p in packs + baselines if g in tu["groups"][p]]))

    # Named
    L.append("## Named scenarios\n")
    L.append("Each named scenario tests one thing, with the sensors above unless the row says otherwise. "
             "F1 of the default and of the best pack on it; every pack and measure is in "
             "[per-scenario.csv](figures/bench/per-scenario.csv).\n")
    import score as scoring
    rows = []
    for m in named:
        d = {p: scoring.derive(res["raw"][p][m["name"]]) for p in packs if res["raw"][p].get(m["name"])}
        top = max(d, key=lambda p: d[p]["f1"] if d[p]["f1"] is not None else -1)
        rows.append([m["name"], m["family"], m["tests"], fmt(d[DEFAULT]["f1"], "{:.3f}"),
                     "%s (%s)" % (fmt(d[top]["f1"], "{:.3f}"), short(top))])
    L.append(table(["Scenario", "Family", "Tests", "F1, default", "F1, best (pack)"], rows))
    if timed:
        L.append("The time scenarios stamp one sensor's reports with a wrong clock: 200 ms ahead, drifting "
                 "10 ms per minute, or running free (1.5 s behind and drifting); each also as an "
                 "\"undescribed\" twin whose reports carry no time quality. Truth is exact; only the stamped "
                 "time is wrong. The object turns 90 degrees every 100 s, so a fixed position bias cannot "
                 "stand in for a clock error.\n")

    # Sources
    L.append("## Data sources\n")
    L.append(table(["Data", "Source", "Terms", "In the repository"], [
        ["generated scenarios", "`tools/bench/scenarios.py`, `tools/bench/dataset.py`", "this repository's license",
         "the generator; the tuning seeds; the evaluation seeds only after a release"],
        ["recorded ship motion (family \"recorded ships\")",
         "NOAA Office for Coastal Management and BOEM, MarineCadastre.gov \"Vessel Traffic (AIS)\", daily file "
         "AIS_2023_01_01 (SHA-256 in `tools/bench/data/recorded-ships.json`)",
         "U.S. Government material, not subject to copyright protection within the United States "
         "(17 U.S.C. 403 notice in NOTICE)",
         "times and positions of 40 thirty-minute windows from open water about 100 km or more offshore, "
         "identifiers removed, moved to the notional reference point (`tools/bench/recorded.py`)"],
        ["Stone Soup", "[github.com/dstl/Stone-Soup](https://github.com/dstl/Stone-Soup), version 1.9.1 from PyPI",
         "MIT license", "nothing: installed by `tools/baselines/requirements.txt`"]]))
    files[DOC] = "\n".join(L)
    return files


def write_all(res):
    for path, text in render_all(res).items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote %s" % os.path.relpath(path, ROOT))
    for old in ("f1-light.svg", "f1-dark.svg", "gospa-light.svg", "gospa-dark.svg"):
        p = os.path.join(FIG, old)
        if os.path.exists(p):
            os.remove(p)


def check_all(res):
    bad = 0
    for path, text in render_all(res).items():
        try:
            with open(path, encoding="utf-8") as f:
                cur = f.read()
        except OSError:
            cur = None
        if cur != text:
            print("not current: %s" % os.path.relpath(path, ROOT))
            bad += 1
    return bad
