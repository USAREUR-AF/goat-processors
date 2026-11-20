"""Write docs/benchmark.md and the SVG charts under docs/figures/bench/ from results.json.

Every number in the documents comes from results.json; nothing is written by hand.
"""

import os

import adapters

ROOT = adapters.ROOT
DOC = os.path.join(ROOT, "docs", "benchmark.md")
FIG = os.path.join(ROOT, "docs", "figures", "bench")

# Categorical slots in fixed order (one per pack, never cycled), light and dark.
SERIES = {
    "light": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"],
    "dark": ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#0ca30c", "#9085e9", "#e66767"],
}

# Packs left out of the charts (eight slots at most), with the reason; they stay in every table.
CHART_OMIT = {"correlate-assign-window": "assign-full includes its multi-frame window",
              "correlate-assign-bias": "assign-full includes its bias estimate",
              "correlate-assign-full": "assign-time is assign-full plus a fitted clock offset",
              "correlate-gnn-time": "its time_default names source radar-1, which no scenario has, "
                                    "so it scores as gnn"}
INK = {
    "light": dict(surface="#fcfcfb", text="#0b0b0b", text2="#52514e", muted="#898781",
                  grid="#e1e0d9", axis="#c3c2b7"),
    "dark": dict(surface="#1a1a19", text="#f0efec", text2="#c3c2b7", muted="#898781",
                 grid="#2c2c2a", axis="#383835"),
}
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

METRICS = [
    ("f1", "Pairwise F1", "{:.3f}", True),
    ("precision", "Precision", "{:.3f}", True),
    ("recall", "Recall", "{:.3f}", True),
    ("false_merges", "False merges", "{:d}", False),
    ("missed_merges", "Missed merges", "{:d}", False),
    ("swaps", "Identity swaps", "{:d}", False),
    ("tta_s", "Time to associate, s", "{:.1f}", False),
    ("rms_m", "Position error RMS, m", "{:.1f}", False),
    ("gospa_m", "GOSPA, m", "{:.1f}", False),
]


def fmt(v, f):
    if v is None:
        return "–"
    if f == "{:d}":
        return str(int(v))
    return f.format(v)


def short(pack):
    return pack[len("correlate-"):] if pack.startswith("correlate-") else pack


def plink(pack):
    """A pack name in a table, linked to its plain description in the README."""
    return "[%s](../README.md#methods-and-packs)" % short(pack)


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


def grouped_bars(title, subtitle, rows, packs, values, mode, vmax=None, fmt_s="{:.2f}"):
    """Horizontal grouped bars: one row per scenario, one bar per pack."""
    ink, cols = INK[mode], SERIES[mode]
    bar, gap, row_pad = 6, 2, 10
    label_w, plot_w, right = 150, 470, 50
    top = 78
    row_h = len(packs) * (bar + gap) - gap + row_pad
    h = top + len(rows) * row_h + 34
    w = label_w + plot_w + right
    vals = [v for r in rows for p in packs for v in [values[p].get(r)] if v is not None]
    vmax = vmax or nice_max(max(vals) if vals else 1.0)
    x = lambda v: label_w + plot_w * min(v, vmax) / vmax  # noqa: E731
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="%s" role="img" aria-label="%s">' % (w, h, w, h, FONT, esc(title)),
         '<rect width="100%%" height="100%%" fill="%s"/>' % ink["surface"],
         '<text x="16" y="26" font-size="15" font-weight="600" fill="%s">%s</text>' % (ink["text"], esc(title)),
         '<text x="16" y="45" font-size="12" fill="%s">%s</text>' % (ink["text2"], esc(subtitle))]
    lx = 16
    for i, p in enumerate(packs):
        o.append('<rect x="%d" y="56" width="10" height="10" rx="2" fill="%s"/>' % (lx, cols[i]))
        o.append('<text x="%d" y="65" font-size="12" fill="%s">%s</text>' % (lx + 14, ink["text2"], esc(short(p))))
        lx += 14 + int(6.5 * len(short(p))) + 16
    for k in range(5):
        v = vmax * k / 4
        gx = x(v)
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" stroke-width="1"/>'
                 % (gx, top - 4, gx, h - 30, ink["grid"]))
        o.append('<text x="%.1f" y="%d" font-size="11" text-anchor="middle" fill="%s">%s</text>'
                 % (gx, h - 14, ink["muted"], esc(fmt_s.format(v))))
    o.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="1"/>'
             % (label_w, top - 4, label_w, h - 30, ink["axis"]))
    for ri, r in enumerate(rows):
        y0 = top + ri * row_h
        o.append('<text x="%d" y="%.1f" font-size="12" text-anchor="end" fill="%s">%s</text>'
                 % (label_w - 8, y0 + (row_h - row_pad) / 2 + 4, ink["text"], esc(r)))
        for i, p in enumerate(packs):
            v = values[p].get(r)
            y = y0 + i * (bar + gap)
            if v is None:
                continue
            bw = max(x(v) - label_w, 1.0)
            o.append('<rect x="%d" y="%d" width="%.1f" height="%d" rx="2" fill="%s"><title>%s, %s: %s</title></rect>'
                     % (label_w, y, bw, bar, cols[i], esc(r), esc(short(p)), esc(fmt_s.format(v))))
    o.append("</svg>")
    return "\n".join(o) + "\n"


def panels(title, subtitle, packs, items, mode):
    """Small multiples: one panel per measure, one bar per pack, each panel its own scale."""
    ink, cols = INK[mode], SERIES[mode]
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
                     % (x0 + lab_w, y, bw, bar, cols[i], esc(short(p)), esc(label), esc(fmt(v, f))))
            o.append('<text x="%.1f" y="%d" font-size="11" fill="%s">%s</text>'
                     % (x0 + lab_w + bw + 4, y + bar - 3, ink["text"], esc(fmt(v, f))))
    o.append("</svg>")
    return "\n".join(o) + "\n"


# ---------------------------------------------------------------------------
# Markdown


def picture(name, alt):
    return ('<picture>\n'
            '  <source media="(prefers-color-scheme: dark)" srcset="figures/bench/%s-dark.svg">\n'
            '  <img alt="%s" src="figures/bench/%s-light.svg">\n'
            '</picture>\n' % (name, esc(alt), name))


def render_all(res):
    """Every generated file: {path: text}."""
    packs = res["packs"]
    cpacks = [p for p in packs if p not in CHART_OMIT]
    if len(cpacks) > len(SERIES["light"]):
        raise SystemExit("more than %d packs to chart: add one to CHART_OMIT" % len(SERIES["light"]))
    import bench as _b
    legacy = _b.named_names()
    named = [m for m in res["meta"] if m["name"] in legacy]   # per-scenario tables and charts: the named set
    random = [m for m in res["meta"] if m["family"] == "random"]
    timed = [m for m in res["meta"] if m["family"] == "time"]
    n_named = len(named) - len(timed)
    S = res["scenarios"]
    files = {}

    # charts
    rows = [m["name"] for m in named]
    f1 = {p: {r: S[p]["per"][r]["f1"] for r in rows} for p in packs}
    gs = {p: {r: S[p]["per"][r]["gospa_m"] for r in rows} for p in packs}
    ev = res.get("evaluation")
    if ev:
        src = {p: ev["groups"][p]["random"]["pooled"] for p in cpacks}
        rtitle = "Evaluation set: %d random scenarios pooled" % ev["groups"][cpacks[0]]["random"]["n"]
    else:
        src = {p: S[p]["random"] for p in cpacks}
        rtitle = "Tuning set: %d random scenarios pooled" % len(random)
    summary = [(lab, [src[p][k] for p in cpacks], f, hi)
               for (k, lab, f, hi) in METRICS if k in ("f1", "swaps", "false_merges", "rms_m", "gospa_m")]
    for mode in ("light", "dark"):
        files[os.path.join(FIG, "f1-%s.svg" % mode)] = grouped_bars(
            "Pairwise association F1 per scenario", "1.0 is every pair of tracks grouped exactly as in truth",
            rows, cpacks, f1, mode, vmax=1.0, fmt_s="{:.2f}")
        files[os.path.join(FIG, "gospa-%s.svg" % mode)] = grouped_bars(
            "GOSPA per scenario, mean over ticks", "meters, c = 500 m, p = 2; lower is better",
            rows, cpacks, gs, mode, fmt_s="{:.0f}")
        files[os.path.join(FIG, "random-%s.svg" % mode)] = panels(
            rtitle, "each panel has its own scale", cpacks, summary, mode)

    L = []
    L.append("# Correlation benchmark\n")
    L.append("Status: Measured. Generated by `python3 -I tools/bench/bench.py report`; "
             "do not edit by hand. Formats and the formula of every score: "
             "[tools/bench/README.md](../tools/bench/README.md).\n")
    L.append("Each scenario places truth objects and sensors that report tracks of them with "
             "stated errors. Every correlate pack runs on the same report stream with the Python "
             "engine, and its output at each tick is scored against truth.\n")
    L.append("Each pack is one set of correlate settings; what each one does, and what it adds over the "
             "pack it extends, is in the README, [Methods and packs](../README.md#methods-and-packs). "
             "The measures, in short: **pairwise F1** checks, at every tick, every pair of live tracks "
             "(together in the output exactly when they are the same object?), from 0 to 1, higher is "
             "better; a **false merge** puts tracks of two objects together; a **missed merge** keeps "
             "one object's tracks apart for 10 s or more; an **identity swap** changes an object's "
             "output track while the old one still exists; **GOSPA** is the mean position error with "
             "each error capped at 500 m and every missed or false track charged half the cap, lower "
             "is better.\n")
    tu = res.get("tuning", {})
    L.append("## Which numbers come from which set\n")
    L.append(table(["Set", "Content", "Seeds", "Use"], [
        ["evaluation", "500 random scenarios and the evaluation half of every family (%s); names start `eval-`"
         % ", ".join(f for f in (ev or {}).get("families", []) if f != "random"),
         "private: held by the benchmark maintainer, published after each release and then rotated",
         "**every number in the README, the comparison and the PDF**; never used to tune a pack"],
        ["tuning", "the 21 named and 7 time scenarios, 500 random scenarios (the first 50 are the earlier "
         "random set) and the tuning half of every family", "public (`tools/bench/dataset.py`)",
         "developing and tuning packs; CI re-runs a subset of it"]]))
    L.append("A pooled measure sums the counts of every scenario of a group and then divides "
             "(tools/bench/README.md, \"Scores\"); its 95 %% interval comes from a bootstrap over the "
             "group's scenarios (1,000 resamples, `tools/bench/stats.py`). A difference between two "
             "packs, or two versions of one, counts as better or worse only when their intervals do not "
             "overlap. A run that exceeds %d s on one scenario is reported as not finished and left out of "
             "its group's pooled measures; the cell says how many.\n" % tu.get("timeout_s", 300))
    if ev:
        L.append("## Evaluation set\n")
        L.append("%d scenarios, run in %d parallel processes in %d min on the benchmark machine "
                 "(the time a full evaluation run takes there).\n" % (ev["scenarios"], ev["jobs"],
                                                                      round(ev["seconds"] / 60.0)))
        L.append(picture("random", "Pooled scores over the evaluation random set, one bar per pack"))
        omitted = [p for p in packs if p in CHART_OMIT]
        if omitted:
            L.append("The charts leave out %s; the tables include every pack.\n" % "; ".join(
                "%s (%s)" % (short(p), CHART_OMIT[p]) for p in omitted))
        set_section(L, packs, ev["groups"], "Random scenarios")
    else:
        L.append("## Evaluation set\n")
        L.append("Not run on this tree: it needs the private seeds.\n")
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
        ["recorded aircraft motion", "OpenSky Network historical data", "not yet checked: the terms could "
         "not be read from the benchmark machine", "nothing"]]))
    L.append("## Tuning set\n")
    L.append("The random generator places 2 to 4 objects (still, straight, turning, accelerating) and 2 or 3 "
             "sensors, each sensor with a chance of understated or absent error, bias, latency, low "
             "detection, a track number swap, a drop, and false tracks. The families are named generators "
             "with stated ground truth; tools/bench/README.md describes each.\n")
    if tu.get("groups"):
        L.append("%d scenarios, run in %d parallel processes in %d min.\n" % (
            len(res["meta"]), tu["jobs"], round(tu["seconds"] / 60.0)))
        set_section(L, packs, tu["groups"], "Random scenarios")
    L.append("### Named scenarios, pooled\n")
    L.append("The %d named scenarios outside the time family.\n" % n_named)
    L.append(table(["Pack"] + [lab for _, lab, _, _ in METRICS],
                   [[plink(p)] + [fmt(S[p]["named"][k], f) for k, _, f, _ in METRICS] for p in packs]))
    if timed:
        L.append("### Time quality set, pooled\n")
        L.append("The %d scenarios of the time family, pooled on their own: a sensor whose clock is "
                 "200 ms ahead, drifting 10 ms per minute, or running free (1.5 s behind and drifting), "
                 "each with every sensor reporting `time_error_ms` and `time_state` and as an "
                 "\"undescribed\" twin with the same reports and no time keys; and reports arriving "
                 "out of order. Truth is exact; only the stamped time is wrong. The object turns 90 "
                 "degrees every 100 s, so a fixed position bias cannot stand in for a clock error.\n"
                 % len(timed))
        L.append(table(["Pack"] + [lab for _, lab, _, _ in METRICS],
                       [[plink(p)] + [fmt(S[p]["time"][k], f) for k, _, f, _ in METRICS] for p in packs]))
    L.append("## Named scenarios\n")
    L.append(table(["Scenario", "Family", "Tests", "Objects", "Reports", "False reports", "Sensors"],
                   [[m["name"], m["family"], m["tests"], str(m["objects"]), str(m["reports"]),
                     str(m["false_reports"]), "; ".join(m["sensors"])] for m in named]))
    L.append("## Association per scenario\n")
    L.append(picture("f1", "Pairwise F1 per named scenario, one bar per pack"))
    families = []
    for m in named:
        if m["family"] not in families:
            families.append(m["family"])
    for fam in families:
        L.append("### %s\n" % fam.capitalize())
        names = [m["name"] for m in named if m["family"] == fam]
        hdr = ["Scenario", "Pack", "F1", "Precision", "Recall", "False merges", "Missed merges",
               "Swaps", "Time to associate, s", "RMS, m", "GOSPA, m"]
        body = []
        for n in names:
            for p in packs:
                d = S[p]["per"][n]
                body.append([n, short(p)] + [fmt(d[k], f) for k, _, f, _ in METRICS])
        L.append(table(hdr, body))
    L.append("## Position per scenario\n")
    L.append(picture("gospa", "GOSPA per named scenario, one bar per pack"))
    L.append(table(["Scenario"] + [short(p) for p in packs],
                   [[r] + [fmt(gs[p][r], "{:.1f}") for p in packs] for r in rows]))
    files[DOC] = "\n".join(L)
    return files


MIN_CI_N = 5   # below this many scenarios a bootstrap interval says nothing; the count is shown instead


def ci_cell(summ, key, f):
    """'value (lo to hi)' for a pooled measure with its 95 % interval."""
    if not summ or not summ.get("pooled"):
        return "–"
    v = summ["pooled"].get(key)
    if v is None:
        return "–"
    ci = (summ.get("ci95") or {}).get(key)
    base = fmt(v, f)
    if summ.get("n", 0) < MIN_CI_N:
        return "%s (%d scenario%s, no interval)" % (base if f != "{:d}" else str(int(v)), summ["n"],
                                                  "" if summ["n"] == 1 else "s")
    if f == "{:d}":
        base = str(int(v))
    return base if not ci else "%s (%s to %s)" % (base, fmt(ci[0], f if f != "{:d}" else "{:.0f}"),
                                                  fmt(ci[1], f if f != "{:d}" else "{:.0f}"))


def set_section(L, packs, groups, title_random):
    """The pooled random-set table and the per-family F1 and GOSPA tables of one set."""
    rnd = {p: groups[p].get("random") for p in packs}
    n = next((g["n"] for g in rnd.values() if g), 0)
    L.append("### %s (%d scenarios), pooled, 95 %% intervals\n" % (title_random, n))
    L.append(table(["Pack"] + [lab for _, lab, _, _ in METRICS],
                   [[plink(p)] + [ci_cell(rnd[p], k, f) for k, _, f, _ in METRICS] for p in packs]))
    fams = sorted(g for g in groups[packs[0]] if g.startswith("family: "))
    if not fams:
        return
    counts = {g: groups[packs[0]][g]["n"] + groups[packs[0]][g]["not_finished"] for g in fams}
    for key, lab, f in (("f1", "Pairwise F1", "{:.3f}"), ("gospa_m", "GOSPA, m", "{:.0f}")):
        L.append("### Families: %s, 95 %% intervals\n" % lab)
        rows = []
        for p in packs:
            row = [plink(p)]
            for g in fams:
                c = groups[p][g]
                cell = ci_cell(c, key, f)
                if c["not_finished"]:
                    cell += " (%d of %d not finished)" % (c["not_finished"], counts[g])
                row.append(cell)
            rows.append(row)
        L.append(table(["Pack"] + ["%s (%d)" % (g[len("family: "):], counts[g]) for g in fams], rows))


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    for r in rows:
        out.append("| " + " | ".join(c.replace("|", "\\|") for c in r) + " |")
    return "\n".join(out) + "\n"


def write_all(res):
    for path, text in render_all(res).items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote %s" % os.path.relpath(path, ROOT))


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
