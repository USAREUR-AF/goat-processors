#!/usr/bin/env python3
"""Draw the repository's figures from the tree and its vectors.

    python3 -I docs/figures/make-figures.py           # write docs/figures/*.svg
    python3 -I docs/figures/make-figures.py --check   # exit 1 if a committed figure is out of date

Each figure is written twice, `<name>-light.svg` and `<name>-dark.svg`, for a
`<picture>` element. Every number and name in a figure is read from the tree:
the vectors, the packs, the engines' directories, or a replay of a vector
through engines/python. The output is deterministic. Standard library only.
"""

import glob
import json
import math
import os
import sys
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path[:0] = [os.path.join(ROOT, "tools", "explain"), os.path.join(ROOT, "engines", "python", "src")]
import explain  # noqa: E402

THEMES = {
    "light": {
        "paper": "#ffffff", "panel": "#f6f8fa", "ink": "#1f2328", "quiet": "#59636e", "rule": "#d1d9e0",
        "line": "#818b98", "accent": "#0969da", "accent_soft": "#ddf4ff", "on_accent": "#ffffff",
        "good": "#1a7f37", "good_bg": "#dafbe1", "crit": "#cf222e", "crit_bg": "#ffebe9", "mute": "#6e7781",
        "s0": "#0969da", "s1": "#bc4c00", "s2": "#1a7f37", "s3": "#8250df",
    },
    "dark": {
        "paper": "#0d1117", "panel": "#161b22", "ink": "#e6edf3", "quiet": "#9198a1", "rule": "#3d444d",
        "line": "#7d8590", "accent": "#4493f8", "accent_soft": "#132c4c", "on_accent": "#0d1117",
        "good": "#3fb950", "good_bg": "#12261e", "crit": "#f85149", "crit_bg": "#2f1517", "mute": "#8b949e",
        "s0": "#4493f8", "s1": "#f0883e", "s2": "#3fb950", "s3": "#bc8cff",
    },
}
SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace"
FUNCTIONS = ["filter", "correlate", "fuse", "quality"]
ENGINES = [("python", "Python"), ("rust", "Rust"), ("go", "Go"), ("java", "Java"),
           ("cpp", "C++"), ("erlang", "Erlang"), ("zig", "Zig")]


def n(v):
    return ("%.1f" % v).rstrip("0").rstrip(".")


def tw(s, size, mono=False, bold=False):
    """Text width estimate; the browser check in the README confirms it."""
    if mono:
        return len(s) * size * 0.61
    w = 0.0
    for c in s:
        if c in "il.,:;|!'`·1 ":
            w += 0.30
        elif c in "ft()[]/-":
            w += 0.36
        elif c in "mwMW@%":
            w += 0.86
        elif c.isupper() or c in "0123456789≤≥²→":
            w += 0.64
        else:
            w += 0.55
    return w * size * (1.06 if bold else 1.0)


def wrap(s, width, size, mono=False, bold=False):
    out, line = [], ""
    for word in s.split(" "):
        t = word if not line else line + " " + word
        if tw(t, size, mono, bold) <= width or not line:
            line = t
        else:
            out.append(line)
            line = word
    if line:
        out.append(line)
    return out


class SVG:
    def __init__(self, w, h, title, desc):
        self.w, self.h, self.title, self.desc = w, h, title, desc
        self.items = []

    def add(self, s):
        self.items.append(s)

    def rect(self, x, y, w, h, fill="panel", stroke="rule", rx=8, sw=1, dash=None):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        self.add('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="{%s}" stroke="{%s}" stroke-width="%s"%s/>'
                 % (n(x), n(y), n(w), n(h), n(rx), fill, stroke, n(sw), d))

    def text(self, x, y, s, size=14, fill="ink", anchor="start", bold=False, mono=False, italic=False):
        self.add('<text x="%s" y="%s" font-size="%s" fill="{%s}" text-anchor="%s"%s%s%s>%s</text>'
                 % (n(x), n(y), n(size), fill, anchor, ' font-weight="600"' if bold else "",
                    ' font-family="%s"' % MONO if mono else "", ' font-style="italic"' if italic else "", escape(s)))

    def lines(self, x, y, rows, size=14, lead=1.4, **kw):
        for i, r in enumerate(rows):
            self.text(x, y + i * size * lead, r, size, **kw)
        return y + len(rows) * size * lead

    def line(self, x1, y1, x2, y2, stroke="line", sw=1.5, dash=None, arrow=False):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        m = ' marker-end="url(#arrow)"' if arrow else ""
        self.add('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="{%s}" stroke-width="%s"%s%s/>'
                 % (n(x1), n(y1), n(x2), n(y2), stroke, n(sw), d, m))

    def path(self, d, stroke="line", fill="none", sw=1.5, dash=None, arrow=False):
        dd = ' stroke-dasharray="%s"' % dash if dash else ""
        m = ' marker-end="url(#arrow)"' if arrow else ""
        f = "none" if fill == "none" else "{%s}" % fill
        self.add('<path d="%s" fill="%s" stroke="{%s}" stroke-width="%s"%s%s/>' % (d, f, stroke, n(sw), dd, m))

    def circle(self, x, y, r, fill="ink", stroke=None, sw=1.5):
        s = ' stroke="{%s}" stroke-width="%s"' % (stroke, n(sw)) if stroke else ""
        f = "none" if fill == "none" else "{%s}" % fill
        self.add('<circle cx="%s" cy="%s" r="%s" fill="%s"%s/>' % (n(x), n(y), n(r), f, s))

    def ellipse(self, x, y, rx, ry, fill="none", stroke="line", sw=1.5, dash=None, opacity=None):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        f = "none" if fill == "none" else "{%s}" % fill
        o = ' fill-opacity="%s"' % opacity if opacity is not None else ""
        self.add('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" fill="%s"%s stroke="{%s}" stroke-width="%s"%s/>'
                 % (n(x), n(y), n(rx), n(ry), f, o, stroke, n(sw), d))

    def render(self, theme):
        t = THEMES[theme]
        body = "\n".join(self.items)
        for k, v in t.items():
            body = body.replace("{%s}" % k, v)
        return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" role="img" '
                'aria-labelledby="t d" font-family="%s">\n<title id="t">%s</title>\n<desc id="d">%s</desc>\n'
                '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
                'orient="auto-start-reverse"><path d="M0,0L10,5L0,10z" fill="%s"/></marker></defs>\n'
                '<rect width="100%%" height="100%%" rx="12" fill="%s"/>\n%s\n</svg>\n'
                % (self.w, self.h, self.w, self.h, SANS.replace("'", "&apos;"), escape(self.title), escape(self.desc),
                   t["line"], t["paper"], body))


def header(f, title, sub):
    """Title and subtitle at the top left."""
    f.text(24, 38, title, 20, bold=True)
    f.text(24, 62, sub, 14, fill="quiet")


# ---------------------------------------------------------------- tree facts
def vectors():
    return sorted(glob.glob(os.path.join(ROOT, "packs", "*", "vectors", "*.json")))


def function_status():
    out = []
    for fn in FUNCTIONS:
        vs = [v for v in vectors() if os.path.basename(os.path.dirname(os.path.dirname(v))).startswith(fn + "-")]
        packs = sorted({os.path.basename(os.path.dirname(os.path.dirname(v))) for v in vs})
        if vs:
            out.append((fn, "Built", "%d packs, %d vectors" % (len(packs), len(vs))))
        elif os.path.isfile(os.path.join(ROOT, "spec", fn + ".md")):
            out.append((fn, "Written", "specification"))
        else:
            out.append((fn, "Designed", "not built"))
    return out


def report_keys():
    keys, sources = [], set()
    for v in vectors():
        for st in json.load(open(v, encoding="utf-8"))["steps"]:
            r = st.get("ingest")
            if isinstance(r, dict):
                for k in r:
                    if k not in keys:
                        keys.append(k)
                if isinstance(r.get("track.source_id"), str):
                    sources.add(r["track.source_id"])
    return keys, sorted(sources)



W = 880          # every figure's width; a README column shows it at about 830 px


def num(v):
    """A trace number as the figures print it: at most four decimals, no trailing zeros."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return str(v).lower()
    if isinstance(v, float):
        return ("%.4f" % v).rstrip("0").rstrip(".")
    return str(v)


def badge(f, x, y, label):
    f.circle(x, y, 10, fill="ink")
    f.text(x, y + 4.5, label, 13, fill="paper", anchor="middle", bold=True)


# ---------------------------------------------------------------- figure 1
def fig_pipeline():
    status = function_status()
    keys, sources = report_keys()
    title = "goat-processors works on the model goat-transformers writes"
    f = SVG(W, 390, title,
            "Message formats are translated by goat-transformers into one shared report model. goat-processors "
            "reads that model and runs filter, correlate, fuse and quality on it (%s). Each function returns "
            "events, a trace record for every test, and a snapshot of its whole state."
            % "; ".join("%s: %s" % (s[0], s[1].lower()) for s in status))
    header(f, title, "Translation is the base layer; every function here works on its output.")
    top, hgt = 92, 274
    cols = [(24, 118), (166, 128), (318, 176), (518, 230), (772, 84)]
    x, w = cols[0]
    f.rect(x, top, w, hgt)
    f.text(x + 12, top + 28, "Sources", 15, bold=True)
    y = f.lines(x + 12, top + 52, ["in the", "vectors:"], 13, fill="quiet")
    f.lines(x + 12, y + 8, sources, 14, mono=True)
    x, w = cols[1]
    f.rect(x, top, w, hgt, dash="5 4")
    f.text(x + 12, top + 28, "goat-", 15, bold=True)
    f.text(x + 12, top + 48, "transformers", 15, bold=True)
    f.lines(x + 12, top + 74, wrap("translates each message format into the shared model", w - 24, 14), 14, fill="quiet")
    f.lines(x + 12, top + hgt - 36, ["separate", "repository"], 13, fill="quiet", italic=True)
    x, w = cols[2]
    f.rect(x, top, w, hgt, fill="accent_soft", stroke="accent")
    f.text(x + 12, top + 28, "Shared model", 15, bold=True)
    f.text(x + 12, top + 48, "one report:", 13, fill="quiet")
    f.lines(x + 12, top + 72, [k for k in keys if k != "stale_ms"], 14, lead=1.36, mono=True)
    x, w = cols[3]
    f.rect(x, top, w, hgt, stroke="accent", sw=2)
    f.text(x + 14, top + 28, "goat-processors", 15, bold=True)
    rh, gap = 50, 8
    for i, (fn, st, detail) in enumerate(status):
        ry = top + 44 + i * (rh + gap)
        built = st == "Built"
        f.rect(x + 12, ry, w - 24, rh, fill="good_bg" if built else "panel", stroke="good" if built else "rule", rx=6)
        f.text(x + 24, ry + 21, fn, 15, bold=True, mono=True)
        f.text(x + w - 24, ry + 21, st, 13, fill="good" if built else "quiet", anchor="end", bold=built)
        f.text(x + 24, ry + 40, detail, 13, fill="quiet")
    x, w = cols[4]
    f.rect(x, top, w, hgt)
    f.text(x + 12, top + 28, "Outputs", 15, bold=True)
    f.lines(x + 12, top + 58, ["events", "trace", "snapshot"], 14, lead=1.6)
    mid = top + hgt / 2
    for (ax, aw), (bx, _) in zip(cols, cols[1:]):
        f.line(ax + aw + 2, mid, bx - 3, mid, sw=2, arrow=True)
    return f


# ---------------------------------------------------------------- figure 2
def fig_decision():
    from goat_correlator import load_pack
    from goat_correlator.engine import _predict_axis
    path = os.path.join(ROOT, "packs", "correlate-gnn", "vectors", "04-separation-dissolves.json")
    d = explain.build(path)
    step = 2
    s = d["steps"][step]
    pk = load_pack(os.path.join(ROOT, "packs", d["pack"]))
    gate = next(t for t in s["trace"] if t["stage"] == "gate" and t["test"] == "mahalanobis")
    a_key, b_key = gate["a"], gate["b"]
    a = s["snapshot"]["entities"][a_key]
    b0 = d["steps"][step - 1]["snapshot"]["entities"][b_key]
    dt = (a["last_time_ms"] - b0["last_time_ms"]) / 1000.0
    q = pk.filter["accel_var"]
    be, bn = _predict_axis(b0["filter"]["east"], dt, q), _predict_axis(b0["filter"]["north"], dt, q)
    ce = float(s["report"].get("ce", pk.filter["default_ce_m"]))
    d2 = ((a["filter"]["east"][0] - be[0]) ** 2 / (be[2] + ce * ce)
          + (a["filter"]["north"][0] - bn[0]) ** 2 / (bn[2] + ce * ce))
    # The figure recomputes the test from the snapshots; it must equal the trace record.
    assert abs(d2 - gate["value"]) <= 1e-9 * max(1, gate["value"]), (d2, gate["value"])
    rx, ry = math.sqrt(gate["limit"] * (be[2] + ce * ce)), math.sqrt(gate["limit"] * (bn[2] + ce * ce))
    reports = {}
    for st in d["steps"][:step + 1]:
        if st.get("xy"):
            reports.setdefault(st["entity"], []).append((st["t"], st["xy"]))
    event = s["events"][0]
    title = "A report inside the other track's predicted region joins a group"
    f = SVG(W, 540, title,
            "Vector %s, step %d: %s at %s s lies inside the 99 %% region where %s was predicted to be "
            "(d² = %s, limit %s). Every confirm test passes, so the engine emits %s with group %s, members %s."
            % (d["name"], step + 1, a_key, num(a["last_time_ms"] / 1000), b_key, num(gate["value"]),
               num(gate["limit"]), event["ev"], event["group"], ", ".join(event["members"])))
    header(f, title, "Vector %s, step %d, replayed through engines/python. Plan in meters." % (d["name"], step + 1))
    px, py, pw, ph = 24, 88, 400, 428
    f.rect(px, py, pw, ph)
    pad = 1.12
    k = min((pw - 40) / (2 * rx * pad), 250 / (2 * ry * pad))
    ox, oy = px + pw / 2, py + 24 + ry * pad * k
    X = lambda e: ox + (e - be[0]) * k
    Y = lambda nn: oy - (nn - bn[0]) * k
    f.ellipse(X(be[0]), Y(bn[0]), rx * k, ry * k, fill="accent_soft", stroke="accent", dash="6 4")
    c_b, c_a = "s1", "s0"
    bt, bxy = reports[b_key][-1]
    (at0, axy0) = reports[a_key][0]
    aex, aey = X(a["filter"]["east"][0]), Y(a["filter"]["north"][0])
    f.line(X(bxy[0]) + 7, Y(bxy[1]), X(be[0]) - 9, Y(bn[0]), stroke=c_b, sw=1.5, arrow=True)
    f.circle(X(bxy[0]), Y(bxy[1]), 5.5, fill=c_b)
    f.path("M%s,%sh16M%s,%sv16" % (n(X(be[0]) - 8), n(Y(bn[0])), n(X(be[0])), n(Y(bn[0]) - 8)), stroke=c_b, sw=2.5)
    f.circle(X(axy0[0]), Y(axy0[1]), 5.5, fill=c_a)
    f.circle(aex, aey, 5.5, fill=c_a)
    f.circle(aex, aey, 10, fill="none", stroke=c_a, sw=2)
    # numbered markers: the b items above their points, the a items below
    marks = [
        (X(bxy[0]), Y(bxy[1]) - 22, "1", "%s, report at %s s" % (b_key, num(bt / 1000)), c_b),
        (X(be[0]), Y(bn[0]) - 24, "2", "%s, predicted to %s s" % (b_key, num(a["last_time_ms"] / 1000)), c_b),
        (X(axy0[0]), Y(axy0[1]) + 22, "3", "%s, report at %s s" % (a_key, num(at0 / 1000)), c_a),
        (aex, aey + 26, "4", "%s, estimate at %s s" % (a_key, num(a["last_time_ms"] / 1000)), c_a),
    ]
    for x, y, lab, _, _ in marks:
        badge(f, x, y, lab)
    f.text(X(be[0]), Y(bn[0]) + ry * k + 22, "dashed: 99 %% region around 2, d² ≤ %s" % num(gate["limit"]), 14,
           fill="accent", anchor="middle", bold=True)
    ky = Y(bn[0]) + ry * k + 56
    for i, (_, _, lab, t, c) in enumerate(marks):
        yy = ky + i * 24
        badge(f, px + 30, yy - 5, lab)
        f.circle(px + 52, yy - 5, 5, fill=c)
        f.text(px + 64, yy, t, 14, mono=True)
    sb = 50
    f.line(px + pw - 20 - sb * k, py + 24, px + pw - 20, py + 24, stroke="quiet", sw=2)
    f.text(px + pw - 20, py + 18, "%d m" % sb, 13, fill="quiet", anchor="end")
    # trace table
    tx, tw_ = 448, 408
    f.text(tx, py + 18, "Trace of step %d: %s against %s" % (step + 1, a_key, b_key), 15, bold=True)
    cx = [tx, tx + 72, tx + 262, tx + 336, tx + tw_]
    hy = py + 50
    for i, h in enumerate(["stage", "test", "value", "limit", "result"]):
        f.text(cx[i], hy, h, 13, fill="quiet", bold=True, anchor="end" if i >= 2 else "start")
    f.line(tx, hy + 8, tx + tw_, hy + 8, stroke="rule", sw=1)
    rows = [t for t in s["trace"] if t["a"] == a_key and t["b"] == b_key]
    keyname = {"track.simulated": "simulated", "@env": "environment"}
    same = [g[1].get("key") for g in pk.gate if g[0] == "same"]
    si = 0
    for i, t in enumerate(rows):
        y = hy + 32 + i * 30
        name = t["test"]
        if name == "same" and si < len(same):
            name = "same " + keyname.get(same[si], same[si])
            si += 1
        res = "skipped" if t.get("skipped") else ("pass" if t["pass"] else "fail")
        f.text(cx[0], y, t["stage"], 14)
        f.text(cx[1], y, name, 14)
        f.text(cx[2], y, num(t["value"]), 14, anchor="end", mono=True)
        f.text(cx[3], y, num(t["limit"]), 14, anchor="end", mono=True)
        f.text(cx[4], y, res, 14, anchor="end", bold=True,
               fill="good" if res == "pass" else "crit" if res == "fail" else "quiet")
        f.line(tx, y + 10, tx + tw_, y + 10, stroke="rule", sw=0.75)
    ey = hy + 32 + len(rows) * 30 + 10
    f.rect(tx, ey, tw_, 64, fill="good_bg", stroke="good")
    f.text(tx + 14, ey + 26, "event %s, group %s" % (event["ev"], event["group"]), 15, bold=True, fill="good")
    f.text(tx + 14, ey + 49, "members " + ", ".join(event["members"]), 14, mono=True)
    return f


# ---------------------------------------------------------------- figure 3
def fig_assign():
    from goat_correlator import load_pack
    path = os.path.join(ROOT, "packs", "correlate-assign", "vectors", "25-assign-least-total-not-nearest-first.json")
    d = explain.build(path)
    pk = load_pack(os.path.join(ROOT, "packs", d["pack"]))
    for i, s in enumerate(d["steps"]):
        costs = [t for t in s["trace"] if t["stage"] == "assign" and t["test"] == "cost"]
        order = []
        for t in costs:
            if t["a"] not in order:
                order.append(t["a"])
        rows = [r for r in order if sum(1 for t in costs if t["a"] == r) > 1]
        if len(rows) >= 2:
            break
    choice = {t["a"]: t["b"] for t in s["trace"] if t["stage"] == "assign" and t["test"] == "choice" and t["a"] in rows}
    systems = []
    for t in costs:
        if t["a"] in rows and t["b"] != "alone" and t["b"] not in systems:
            systems.append(t["b"])
    cost = {(t["a"], t["b"]): t["value"] for t in costs if t["a"] in rows}
    new_cost = pk.new_cost
    others = {sy: [m for m in s["snapshot"]["systems"][sy] if m not in rows] for sy in systems}
    cols = systems + ["alone:" + r for r in rows]
    pick = {r: (choice[r] if choice[r] != "alone" else "alone:" + r) for r in rows}

    def entry(r, c):
        if c.startswith("alone:"):
            return cost[(r, "alone")] if c == "alone:" + r else None
        return cost.get((r, c))

    total = sum(entry(r, pick[r]) for r in rows)
    taken, greedy, gsum = set(), {}, 0.0
    for r in rows:
        best = min((c for c in cols if c not in taken and entry(r, c) is not None), key=lambda c: entry(r, c))
        taken.add(best)
        greedy[r] = best
        gsum += entry(r, best)
    short = lambda e: e.split("/", 1)[1]
    src = rows[0].split("/")[0]
    title = "Assignment takes the least total cost, not each track's nearest"
    gx, gy, lw, cw, rh = 24, 128, 128, 120, 64
    by = gy + len(rows) * rh + 36
    f = SVG(W, by + 110, title,
            "Vector %s, tick at step %d, source %s: rows are its tracks, columns the system tracks and one "
            "alone entry per track at new_cost %s; another track's alone entry is forbidden. The chosen "
            "assignment totals %.3f; taking each row's nearest in turn would total %.3f."
            % (d["name"], i + 1, src, num(new_cost), total, gsum))
    header(f, title, "Vector %s, step %d: source %s's cost matrix, read from the trace."
           % (d["name"], i + 1, src))
    f.text(gx, gy - 14, "cost d²", 13, fill="quiet")
    for j, c in enumerate(cols):
        x = gx + lw + j * cw + cw / 2
        if c.startswith("alone:"):
            f.text(x, gy - 32, "alone", 14, anchor="middle", bold=True)
            f.text(x, gy - 12, short(c.split(":", 1)[1]), 13, anchor="middle", fill="quiet", mono=True)
        else:
            f.text(x, gy - 32, "system " + c, 14, anchor="middle", bold=True)
            f.text(x, gy - 12, ", ".join(others[c]), 13, anchor="middle", fill="quiet", mono=True)
    for ii, r in enumerate(rows):
        y = gy + ii * rh
        f.text(gx, y + rh / 2 + 5, r, 14, mono=True, bold=True)
        for j, c in enumerate(cols):
            x = gx + lw + j * cw
            v = entry(r, c)
            chosen, nearest = pick[r] == c, greedy[r] == c and pick[r] != c
            if v is None:
                f.rect(x + 3, y + 3, cw - 6, rh - 6, fill="panel", stroke="rule", rx=6, dash="3 3")
                f.text(x + cw / 2, y + rh / 2 + 5, "forbidden", 13, anchor="middle", fill="quiet", italic=True)
                continue
            f.rect(x + 3, y + 3, cw - 6, rh - 6, fill="accent" if chosen else "panel",
                   stroke="accent" if chosen else ("crit" if nearest else "rule"), rx=6,
                   sw=2 if (chosen or nearest) else 1, dash="5 3" if nearest else None)
            alone = c.startswith("alone:")
            f.text(x + cw / 2, y + rh / 2 + (-3 if alone else 6), "%.3f" % v, 15, anchor="middle",
                   fill="on_accent" if chosen else "ink", mono=True, bold=chosen)
            if alone:
                f.text(x + cw / 2, y + rh / 2 + 16, "new_cost", 13, anchor="middle", fill="on_accent" if chosen else "quiet")
    lab = lambda m: ", ".join("%s → %s" % (short(r), m[r] if not m[r].startswith("alone:") else "alone") for r in rows)
    f.rect(gx, by - 15, 36, 20, fill="accent", stroke="accent", rx=5)
    f.text(gx + 48, by, "chosen: %s, total %.3f" % (lab(pick), total), 15, bold=True)
    f.rect(gx, by + 17, 36, 20, fill="panel", stroke="crit", rx=5, sw=2, dash="5 3")
    f.text(gx + 48, by + 32, "nearest first: %s, total %.3f" % (lab(greedy), gsum), 15)
    f.rect(gx, by + 49, 36, 20, fill="panel", stroke="rule", rx=5, dash="3 3")
    f.text(gx + 48, by + 64, "forbidden: a track may only take its own alone entry", 15)
    nx = 556
    note = wrap("%s's nearest system track is %s (%.3f). Taking %s instead lets %s take %s, and the total is "
                "%.3f lower." % (short(rows[0]), greedy[rows[0]], entry(rows[0], greedy[rows[0]]), pick[rows[0]],
                                 short(rows[1]), pick[rows[1]], gsum - total), W - 24 - nx - 28, 14)
    f.rect(nx, by - 24, W - 24 - nx, 28 + len(note) * 20, fill="panel", stroke="rule")
    f.lines(nx + 14, by, note, 14, lead=1.43)
    return f


# ---------------------------------------------------------------- figure 4
def fig_engines():
    vs = vectors()
    steps = traces = 0
    for v in vs:
        for st in json.load(open(v, encoding="utf-8"))["steps"]:
            steps += 1
            traces += len(st.get("trace", []))
    loads = len(glob.glob(os.path.join(ROOT, "spec", "*-load-vectors", "*.json")))
    present = [(k, name) for k, name in ENGINES if os.path.isdir(os.path.join(ROOT, "engines", k))]
    words = {2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine"}
    title = "%s engines, written apart, must give the same answer on every vector" % words.get(len(present), len(present))
    f = SVG(W, 500, title,
            "%d scenario vectors (%d steps, %d trace records) and %d load vectors sit at the center. "
            "each generator under tools/ states its decisions by hand and the Python engine computes the numbers; "
            "the %s engines are written from the specification and the vectors alone and must reproduce every "
            "event, trace record and final snapshot." % (len(vs), steps, traces, loads,
                                                        ", ".join(name for _, name in present[1:])))
    header(f, title, "Each engine reads the specification and the vectors only. A disagreement is filed, not patched.")
    cx, cy = W / 2, 274
    w, h = 236, 124
    f.rect(cx - w / 2, cy - h / 2, w, h, fill="accent_soft", stroke="accent", sw=2)
    f.text(cx, cy - 30, "packs/*/vectors", 15, anchor="middle", bold=True, mono=True)
    f.text(cx, cy - 4, "%d vectors · %d steps" % (len(vs), steps), 14, anchor="middle")
    f.text(cx, cy + 18, "%d trace records" % traces, 14, anchor="middle")
    f.text(cx, cy + 40, "+ %d load vectors" % loads, 14, anchor="middle", fill="quiet")
    bw, bh = 148, 56
    rx, ry = 318, 156
    for i, (k, name) in enumerate(present):
        ang = -math.pi / 2 + 2 * math.pi * i / len(present)
        x, y = cx + rx * math.cos(ang), cy + ry * math.sin(ang)
        ref = i == 0
        f.rect(x - bw / 2, y - bh / 2, bw, bh, fill="good_bg" if ref else "panel", stroke="good" if ref else "rule", sw=1.5)
        f.text(x, y - 5, name, 15, anchor="middle", bold=True)
        f.text(x, y + 16, "engines/" + k, 13, anchor="middle", fill="quiet", mono=True)
        dx, dy = x - cx, y - cy
        tc = min((w / 2 + 6) / abs(dx) if dx else 1e9, (h / 2 + 6) / abs(dy) if dy else 1e9)
        te = 1 - min((bw / 2 + 6) / abs(dx) if dx else 1e9, (bh / 2 + 6) / abs(dy) if dy else 1e9)
        p0, p1 = (cx + dx * tc, cy + dy * tc), (cx + dx * te, cy + dy * te)
        if ref:
            f.line(p1[0], p1[1], p0[0], p0[1], stroke="good", sw=2, arrow=True)
        else:
            f.line(p0[0], p0[1], p1[0], p1[1], sw=1.5, arrow=True)
    ky = 474
    f.rect(24, ky - 14, 18, 18, fill="good_bg", stroke="good", rx=4)
    f.text(50, ky, "reference: writes the vectors' numbers", 14)
    f.line(386, ky - 5, 414, ky - 5, sw=1.5, arrow=True)
    f.text(424, ky, "checks: must reproduce each one, numbers within 1e-6", 14)
    return f


FIGURES = [("processing-layer", fig_pipeline), ("correlate-decision", fig_decision),
           ("assign-matrix", fig_assign), ("seven-engines", fig_engines)]


def main(argv):
    check = "--check" in argv
    stale = []
    for name, fn in FIGURES:
        fig = fn()
        for theme in THEMES:
            p = os.path.join(HERE, "%s-%s.svg" % (name, theme))
            out = fig.render(theme)
            if check:
                if not os.path.isfile(p) or open(p, encoding="utf-8").read() != out:
                    stale.append(os.path.relpath(p, ROOT))
            else:
                with open(p, "w", encoding="utf-8") as fh:
                    fh.write(out)
                print(os.path.relpath(p, ROOT))
    if stale:
        print("out of date: " + ", ".join(stale) + "; run python3 -I docs/figures/make-figures.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
