#!/usr/bin/env python3
"""Write one self-contained HTML page that replays a vector or a bench run.

    python3 -I tools/explain/explain.py packs/correlate-gnn/vectors/01-two-sources-one-object.json
    python3 -I tools/explain/explain.py run.json --truth truth.json -o run.html

The page shows a plan view of every entity's reports and filter estimate with
its uncertainty ellipse, the groups or system tracks as they form and
dissolve, a step slider, and for the selected step the input, the events,
every trace record and the snapshot. It makes no network request.

When the Python engine for the vector's function is present, the tool replays
the steps through it to obtain the snapshot after every step, and marks each
step whose events or trace differ from the vector. Without an engine it shows
what the file holds: the steps, their events and trace, and the final snapshot.

Standard library only.
"""

import argparse
import html
import importlib
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
R = 6371008.8          # mean Earth radius, meters; the plane of spec/correlate.md
TOL = 1e-6             # spec/vector-format.md number tolerance

# Function prefix of a pack name -> Python engine module under engines/python/src.
ENGINES = {"correlate": "goat_correlator", "filter": "goat_filter", "fuse": "goat_fuse", "quality": "goat_quality"}


# ---------------------------------------------------------------- comparison
def equal(got, want):
    """Structural equality of spec/vector-format.md."""
    if isinstance(want, bool) or isinstance(got, bool) or want is None or got is None:
        return got is want or (type(got) is type(want) and got == want)
    if isinstance(want, (int, float)):
        return isinstance(got, (int, float)) and abs(got - want) <= TOL * max(1.0, abs(want))
    if isinstance(want, str):
        return got == want
    if isinstance(want, list):
        return isinstance(got, list) and len(got) == len(want) and all(equal(g, w) for g, w in zip(got, want))
    if isinstance(want, dict):
        return isinstance(got, dict) and set(got) == set(want) and all(equal(got[k], want[k]) for k in want)
    return False


def first_difference(got, want, path="$"):
    """The path of the first difference between two values, with both values."""
    if equal(got, want):
        return None
    if isinstance(want, list) and isinstance(got, list) and len(got) == len(want):
        for i, (g, w) in enumerate(zip(got, want)):
            d = first_difference(g, w, "%s[%d]" % (path, i))
            if d:
                return d
    if isinstance(want, dict) and isinstance(got, dict) and set(got) == set(want):
        for k in sorted(want):
            d = first_difference(got[k], want[k], "%s.%s" % (path, k))
            if d:
                return d
    short = lambda v: json.dumps(v, sort_keys=True)[:160]
    return "%s: replay %s, vector %s" % (path, short(got), short(want))


# ---------------------------------------------------------------- engine
def load_engine(pack):
    """Return (make, load_pack, note) for the pack's function, or (None, None, note)."""
    fn = pack.split("-", 1)[0]
    mod = ENGINES.get(fn)
    if mod is None:
        return None, None, "no Python engine is registered for function '%s'; showing the file only" % fn
    src = os.path.join(ROOT, "engines", "python", "src")
    if src not in sys.path:
        sys.path.insert(0, src)
    try:
        m = importlib.import_module(mod)
    except ImportError as e:
        return None, None, "engine %s not importable (%s); showing the file only" % (mod, e)
    make = getattr(m, "make_engine", None) or getattr(m, "Engine")
    return make, m.load_pack, "replayed through engines/python (%s)" % mod


def replay(vec, pack_dir):
    make, load, note = load_engine(vec["pack"])
    if make is None or not os.path.isdir(pack_dir):
        return None, note if make is None else "pack directory %s not found; showing the file only" % pack_dir
    eng = make(load(pack_dir))
    out = []
    for st in vec["steps"]:
        ev, tr = eng.ingest(st["ingest"]) if "ingest" in st else eng.tick(st["tick"])
        out.append((ev, tr, eng.snapshot()))
    return out, note


# ---------------------------------------------------------------- geometry
def wrap180(x):
    while x > 180.0:
        x -= 360.0
    while x <= -180.0:
        x += 360.0
    return x


def to_plane(ref, lat, lon):
    lat0, lon0 = ref
    return (R * math.radians(wrap180(lon - lon0)) * math.cos(math.radians(lat0)),
            R * math.radians(lat - lat0))


def entity_key(rep):
    src = rep.get("track.source_id")
    return "%s/%s" % (src, rep.get("uid")) if src is not None else str(rep.get("uid"))


def first_ref(vec, snaps):
    for s in snaps or []:
        if s and s.get("ref"):
            return s["ref"]
    if vec.get("snapshot", {}).get("ref"):
        return vec["snapshot"]["ref"]
    for st in vec["steps"]:
        r = st.get("ingest")
        if r and isinstance(r.get("lat"), (int, float)) and isinstance(r.get("lon"), (int, float)):
            return [r["lat"], r["lon"]]
    return [0.0, 0.0]


def estimates(snap):
    """entity -> [east, north, sigma_east, sigma_north, t] from a snapshot's filters."""
    out = {}
    for k, e in (snap or {}).get("entities", {}).items():
        f = e.get("filter") if isinstance(e, dict) else None
        if not f or "east" not in f or "north" not in f:
            continue
        ea, no = f["east"], f["north"]
        out[k] = [ea[0], no[0], math.sqrt(max(ea[2], 0.0)), math.sqrt(max(no[2], 0.0)),
                  e.get("last_time_ms"), ea[1], no[1]]
    return out


def clusters(snap):
    """{'kind': 'group'|'system', id: members} from a snapshot."""
    snap = snap or {}
    for kind, key in (("group", "groups"), ("system", "systems")):
        if isinstance(snap.get(key), dict):
            return kind, snap[key]
    return None, {}


# ---------------------------------------------------------------- truth
def load_truth(path, ref):
    """Truth as {object: [[t, east, north], ...]}; accepts the shapes listed in README.md."""
    if not path:
        return None, None
    d = json.load(open(path, encoding="utf-8"))
    rows = []
    if isinstance(d, dict) and isinstance(d.get("objects"), dict):
        for oid, pts in d["objects"].items():
            for p in pts:
                rows.append((oid, p))
    elif isinstance(d, dict) and isinstance(d.get("objects"), list):
        for o in d["objects"]:
            for p in o.get("states", o.get("points", [])):
                rows.append((o.get("id"), p))
    elif isinstance(d, list):
        rows = [(p.get("id", p.get("object")), p) for p in d]
    out = {}
    for oid, p in rows:
        if not isinstance(p, dict) or "lat" not in p or "lon" not in p:
            continue
        e, n = to_plane(ref, p["lat"], p["lon"])
        out.setdefault(str(oid), []).append([p.get("time_ms", p.get("t_ms")), e, n])
    if not out:
        return None, "truth file %s has no object positions in a known shape; not drawn" % path
    for v in out.values():
        v.sort(key=lambda r: (r[0] is None, r[0]))
    return out, "truth from %s" % os.path.relpath(path)


# ---------------------------------------------------------------- build
def build(vec_path, truth_path=None, events_path=None):
    vec = json.load(open(vec_path, encoding="utf-8"))
    vec.setdefault("name", os.path.splitext(os.path.basename(vec_path))[0])
    pack = vec.get("pack", "")
    pack_dir = os.path.join(ROOT, "packs", pack)
    pack_def = None
    pdf = os.path.join(pack_dir, "pack.def")
    if pack and os.path.isfile(pdf):
        pack_def = open(pdf, encoding="utf-8").read()

    rep, note = replay(vec, pack_dir) if pack else (None, "the file names no pack; showing the file only")
    ext = None
    if events_path:
        ext = json.load(open(events_path, encoding="utf-8"))
        ext = ext.get("steps", ext) if isinstance(ext, dict) else ext

    snaps = [r[2] for r in rep] if rep else [None] * len(vec["steps"])
    ref = first_ref(vec, snaps)
    steps = []
    mism = 0
    for i, st in enumerate(vec["steps"]):
        kind = "ingest" if "ingest" in st else "tick"
        s = {"i": i, "kind": kind}
        if kind == "ingest":
            r = st["ingest"]
            s["report"] = r
            s["t"] = r.get("time_ms")
            s["entity"] = entity_key(r)
            if isinstance(r.get("lat"), (int, float)) and isinstance(r.get("lon"), (int, float)):
                s["xy"] = list(to_plane(ref, r["lat"], r["lon"]))
                if isinstance(r.get("ce"), (int, float)):
                    s["ce"] = r["ce"]
        else:
            s["t"] = st["tick"]
        want_ev, want_tr = st.get("expect"), st.get("trace")
        if rep:
            ev, tr, sn = rep[i]
            s["events"], s["trace"], s["snapshot"] = ev, tr, sn
            s["match_events"] = None if want_ev is None else equal(ev, want_ev)
            s["match_trace"] = None if want_tr is None else equal(tr, want_tr)
            if s["match_events"] is False or s["match_trace"] is False:
                mism += 1
                s["want_events"], s["want_trace"] = want_ev, want_tr
                s["diffs"] = [d for d in (first_difference(ev, want_ev or [], "events"),
                                          first_difference(tr, want_tr or [], "trace")) if d]
        else:
            s["events"], s["trace"] = want_ev or [], want_tr or []
        if ext is not None and i < len(ext):
            e = ext[i]
            s["events"] = e.get("events", e.get("expect", e)) if isinstance(e, dict) else e
            s["events_source"] = os.path.relpath(events_path)
        for e in s["events"]:
            if isinstance(e, dict) and isinstance(e.get("lat"), (int, float)) and isinstance(e.get("lon"), (int, float)):
                e["_xy"] = list(to_plane(ref, e["lat"], e["lon"]))
        snap = s.get("snapshot")
        s["est"] = estimates(snap)
        s["cluster_kind"], s["clusters"] = clusters(snap)
        steps.append(s)

    final = vec.get("snapshot")
    snap_match = None
    if rep and final is not None:
        snap_match = equal(rep[-1][2], final)
    if not rep and final is not None and steps:
        steps[-1]["snapshot"] = final
        steps[-1]["est"] = estimates(final)
        steps[-1]["cluster_kind"], steps[-1]["clusters"] = clusters(final)

    truth, tnote = load_truth(truth_path, ref)
    return {
        "name": vec["name"],
        "pack": pack,
        "file": os.path.relpath(vec_path, ROOT) if os.path.abspath(vec_path).startswith(ROOT) else os.path.basename(vec_path),
        "pack_def": pack_def,
        "replayed": bool(rep),
        "note": note,
        "truth_note": tnote,
        "mismatch_steps": mism,
        "snapshot_match": snap_match,
        "has_expect": any("expect" in st for st in vec["steps"]),
        "ref": ref,
        "steps": steps,
        "truth": truth,
    }


def finite(v):
    """JSON has no infinity or NaN; write them as the strings "inf", "-inf", "nan"."""
    if isinstance(v, float) and not math.isfinite(v):
        return "nan" if v != v else ("inf" if v > 0 else "-inf")
    if isinstance(v, dict):
        return {k: finite(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [finite(x) for x in v]
    return v


def render(data):
    tpl = open(os.path.join(HERE, "viewer.html"), encoding="utf-8").read()
    js = json.dumps(finite(data), allow_nan=False, separators=(",", ":"), sort_keys=True).replace("</", "<\\/")
    return (tpl.replace("{{TITLE}}", html.escape(data["name"]))
               .replace("{{DATA}}", js))


def write_all(out_dir):
    """One page per vector under packs/, and an index page linking them."""
    import glob
    os.makedirs(out_dir, exist_ok=True)
    rows, bad = [], 0
    for f in sorted(glob.glob(os.path.join(ROOT, "packs", "*", "vectors", "*.json"))):
        d = build(f)
        name = "%s--%s.html" % (d["pack"], d["name"])
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as fh:
            fh.write(render(d))
        ok = d["replayed"] and not d["mismatch_steps"] and d["snapshot_match"] is not False
        bad += not ok
        rows.append("<tr><td>%s</td><td><a href=\"%s\">%s</a></td><td>%d</td><td>%d</td><td class=\"%s\">%s</td></tr>" % (
            html.escape(d["pack"]), html.escape(name), html.escape(d["name"]), len(d["steps"]),
            sum(len(st["trace"]) for st in d["steps"]), "ok" if ok else "bad", "matches" if ok else "differs"))
    page = INDEX.replace("{{ROWS}}", "\n".join(rows)).replace("{{COUNT}}", str(len(rows)))
    with open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(page)
    print("%s: %d vector pages, %d differ from their vector" % (os.path.join(out_dir, "index.html"), len(rows), bad))
    return 1 if bad else 0


INDEX = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Vectors · explain</title>
<style>
:root { --paper: #fff; --ink: #1f2328; --quiet: #59636e; --rule: #d1d9e0; --accent: #0969da; --good: #1a7f37; --crit: #cf222e; color-scheme: light; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --paper: #0d1117; --ink: #e6edf3; --quiet: #9198a1; --rule: #3d444d; --accent: #4493f8; --good: #3fb950; --crit: #f85149; color-scheme: dark; } }
:root[data-theme="dark"] { --paper: #0d1117; --ink: #e6edf3; --quiet: #9198a1; --rule: #3d444d; --accent: #4493f8; --good: #3fb950; --crit: #f85149; color-scheme: dark; }
body { margin: 0 auto; max-width: 900px; padding: 20px 16px; background: var(--paper); color: var(--ink); font: 14px/1.45 system-ui, sans-serif; }
h1 { font-size: 20px; } p { color: var(--quiet); } a { color: var(--accent); }
table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 5px 8px; border-bottom: 1px solid var(--rule); overflow-wrap: anywhere; }
th { color: var(--quiet); font-size: 12px; } td.ok { color: var(--good); font-weight: 600; } td.bad { color: var(--crit); font-weight: 600; }
</style></head><body>
<h1>Every vector, replayed</h1>
<p>{{COUNT}} vectors from packs/*/vectors, each replayed through engines/python and compared step by step. Written by tools/explain/explain.py --all.</p>
<table><thead><tr><th>pack</th><th>vector</th><th>steps</th><th>trace records</th><th>replay</th></tr></thead><tbody>
{{ROWS}}
</tbody></table></body></html>
"""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input", nargs="?", help="a vector file, or a bench run in vector-format input (steps only)")
    ap.add_argument("--all", metavar="DIR", help="write a page for every vector in packs/ and an index.html into DIR")
    ap.add_argument("-o", "--out", help="output HTML (default: <input name>.html in the current directory)")
    ap.add_argument("--truth", help="bench truth file: object positions over time")
    ap.add_argument("--events", help="events file to show instead of the replayed events (another engine's output)")
    a = ap.parse_args(argv)
    if a.all:
        return write_all(a.all)
    if not a.input:
        ap.error("give an input file or --all DIR")
    data = build(a.input, a.truth, a.events)
    out = a.out or os.path.splitext(os.path.basename(a.input))[0] + ".html"
    with open(out, "w", encoding="utf-8") as f:
        f.write(render(data))
    status = data["note"]
    if data["replayed"] and data["has_expect"]:
        status += "; %d step(s) differ from the vector; final snapshot %s" % (
            data["mismatch_steps"], {True: "matches", False: "differs", None: "not compared"}[data["snapshot_match"]])
    print("%s: %d steps, %s" % (out, len(data["steps"]), status))
    return 1 if data["mismatch_steps"] or data["snapshot_match"] is False else 0


if __name__ == "__main__":
    sys.exit(main())
