#!/usr/bin/env python3
"""Performance review: measure a pack, record the result, check a record.

Commands (run with `python3 -I`):

  status                       what is measured per function, and what is not
  try PACK [--against PACK]    measure PACK on the public tuning set and compare it
  record SLUG PACK --kind KIND --question TEXT --finding TEXT [--against PACK]
                               the same, and write reviews/SLUG.json
  check [--rerun] [FILE ...]   check records (default: all); --rerun measures each again

Options of try and record:
  --against PACK   the pack to compare with (default: PACK itself, as committed at BASE)
  --base REF       where the committed results are read (default: origin/main, else HEAD)
  --group TEXT     only groups whose name contains TEXT (try only)
  --jobs N         worker processes for correlate (default: CPU count minus 2)

KIND is one of:
  improve     a change that makes a measure better; needs at least one "better"
  replicate   the committed numbers, measured again by someone else
  measure     a result worth keeping that is neither, including "this did not help"

The rules, the words and the whole path: reviews/README.md.
"""

import argparse
import json
import math
import os
import platform
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))

import functions as fb  # noqa: E402
import stats  # noqa: E402

REVIEWS = os.path.join(ROOT, "reviews")
SCHEMA = 2     # 2: each measure holds gain_ci95, the paired interval; 1: the earlier interval-overlap rule
KINDS = ("improve", "replicate", "measure")
KEYS = {"schema", "slug", "kind", "function", "pack", "against", "base", "set", "question", "finding",
        "environment", "groups", "better", "worse"}
HIGHER = {"f1", "precision", "recall", "idf1", "completeness", "longest_segment"}
LOWER = {"false_merges", "missed_merges", "swaps", "tta_s", "rms_m", "gospa_m", "delay_s", "spuriousness",
         "track_changes_per_min", "siap_pa_m"}
TOWARD_ONE = {"ambiguity"}
# The same code on another machine may differ in the last bit of a float. Counts match exactly.
RERUN_TOLERANCE = 1e-6


class Refused(Exception):
    pass


def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def function_of(pack):
    f = pack.split("-")[0]
    if f not in ("correlate", "filter", "fuse", "quality") or not re.fullmatch(r"[a-z0-9-]+", pack):
        raise Refused("%s: a pack name starts with correlate-, filter-, fuse- or quality-" % pack)
    if not os.path.isdir(os.path.join(ROOT, "packs", pack)):
        raise Refused("packs/%s does not exist" % pack)
    if f in fb.PACKS and pack not in fb.PACKS[f]:
        raise Refused("%s has no accuracy case yet (%s). Adding one is a contribution: reviews/README.md"
                      % (pack, fb.NOT_COVERED.get(pack, "add it to PACKS in tools/bench/functions.py")))
    return f


def base_commit(ref):
    for r in ([ref] if ref else ["origin/main", "HEAD"]):
        sha = git("rev-parse", "--verify", "--quiet", r + "^{commit}")
        if sha:
            merge = git("merge-base", sha.strip(), "HEAD")
            return (merge or sha).strip()
    raise Refused("%s is not a commit here" % (ref or "HEAD"))


def committed(function, pack, base):
    """{group: summary with "runs"} of a pack as committed at `base`.

    "runs" is the list of raw counts per scenario the summary pools: for correlate a
    {scenario: raw} map, for the other functions a list in case order."""
    path = "docs/figures/bench/" + ("results.json" if function == "correlate" else "functions.json")
    text = git("show", "%s:%s" % (base, path))
    if text is None:
        raise Refused("%s has no %s" % (base[:12], path))
    doc = json.loads(text)
    got = (doc["tuning"]["groups"] if function == "correlate" else doc[function]).get(pack)
    if got is None:
        raise Refused("%s has no committed results at %s: name the pack to compare with, --against PACK"
                      % (pack, base[:12]))
    got = {g: dict(s) for g, s in got.items() if g != "family: scale"}   # results from before scale left the sets
    if function == "correlate":
        import bench
        raw = (doc.get("raw") or {}).get(pack) or {}
        for g, names in bench.groups_of(doc["meta"]).items():
            if g in got:
                got[g]["runs"] = {n: raw.get(n) for n in names}
    return got


def measure(function, pack, jobs=None):
    """{group: summary with "runs"}, measured on this checkout."""
    if function != "correlate":
        return fb.score_pack(function, pack)
    import bench
    scs = bench.all_scenarios("tuning")
    metas, raw, _ = bench.run_parallel(scs, packs=[pack], jobs=jobs, label=pack)
    out = bench.summarize(raw, metas)[pack]
    for g, names in bench.groups_of(metas).items():
        out[g]["runs"] = {n: raw[pack].get(n) for n in names}
    return out


def verdict(m, old, new):
    """Schema 1 records: better or worse only when the two 95 % intervals do not overlap."""
    if not old or not new or m not in HIGHER | LOWER:
        return "no difference shown"
    if old[1] < new[0]:
        return "better" if m in HIGHER else "worse"
    if new[1] < old[0]:
        return "worse" if m in HIGHER else "better"
    return "no difference shown"


def _paired(function, a_runs, b_runs, measures):
    """The paired interval of each measure (stats.paired) on the runs both hold."""
    if a_runs is None or b_runs is None:
        return {}
    if isinstance(a_runs, dict):
        names = [n for n in a_runs if a_runs[n] is not None and b_runs.get(n) is not None]
        a, b = [a_runs[n] for n in names], [b_runs[n] for n in names]
    elif len(a_runs) == len(b_runs):
        a, b = a_runs, b_runs
    else:
        return {}
    if not a:
        return {}
    if function == "correlate":
        return stats.paired(a, b, measures=measures)
    return stats.paired(a, b, measures=measures, derive=fb.DERIVE[function])


def compare(old, new, function="correlate"):
    groups = {}
    for g in sorted(new):
        if g not in old:
            continue
        a, b = old[g], new[g]
        ms = [m for m in (stats.MEASURES if "rms_m" in b["pooled"] and "f1" in b["pooled"] else sorted(b["pooled"]))
              if b["pooled"].get(m) is not None and a["pooled"].get(m) is not None]
        gains = _paired(function, a.get("runs"), b.get("runs"), [m for m in ms if m in HIGHER | LOWER | TOWARD_ONE])
        rows = {}
        for m in ms:
            rows[m] = {"value": b["pooled"][m], "ci95": b["ci95"].get(m),
                       "base_value": a["pooled"][m], "base_ci95": a["ci95"].get(m), "gain_ci95": gains.get(m)}
        groups[g] = {"n": b["n"], "not_finished": b.get("not_finished", 0), "measures": rows}
    return groups


def outcomes(groups):
    """Better and worse measures: from the paired interval (schema 2), or the overlap rule (schema 1)."""
    out = {"better": [], "worse": []}
    for g in sorted(groups):
        for m, r in groups[g]["measures"].items():
            v = stats.verdict(r["gain_ci95"]) if "gain_ci95" in r else verdict(m, r["base_ci95"], r["ci95"])
            if v in out:
                out[v].append("%s: %s" % (g, m))
    return out


def show(pack, against, groups, only=None):
    out = outcomes(groups)
    print("%s against %s" % (pack, against))
    for g, d in groups.items():
        if only and only not in g:
            continue
        print("\n%s (%d scenarios%s)" % (g, d["n"], ", %d not finished" % d["not_finished"] if d["not_finished"] else ""))
        for m, r in d["measures"].items():
            v = stats.verdict(r.get("gain_ci95"))
            print("  %-22s %12.4g -> %-12.4g %s" % (m, r["base_value"], r["value"], "" if v.startswith("no") else v))
    print("\nbetter: %d, worse: %d (every other measure: the paired interval of the difference includes zero)"
          % (len(out["better"]), len(out["worse"])))


def errors_in(rec, slug):
    """Everything wrong with a record, without running anything."""
    if not isinstance(rec, dict) or set(rec) != KEYS:
        return ["keys must be exactly: %s" % ", ".join(sorted(KEYS))]
    bad = []
    if rec["schema"] not in (1, SCHEMA):
        bad.append("schema must be %d" % SCHEMA)
    if rec["slug"] != slug or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug):
        bad.append("slug must be the file name, in lower-case words joined by hyphens")
    if rec["kind"] not in KINDS:
        bad.append("kind must be one of %s" % ", ".join(KINDS))
    if rec["set"] != "tuning":
        bad.append("set must be tuning: contributed results never come from the held-out set")
    if not re.fullmatch(r"[0-9a-f]{40}", str(rec["base"])):
        bad.append("base must be a full commit id")
    for k in ("question", "finding"):
        if not isinstance(rec[k], str) or len(rec[k].strip()) < 20:
            bad.append("%s must be a sentence" % k)
    if not isinstance(rec["environment"], dict) or set(rec["environment"]) != {"python", "system", "machine"}:
        bad.append("environment must hold python, system and machine only")
    try:
        if function_of(rec["pack"]) != rec["function"] or function_of(rec["against"]) != rec["function"]:
            bad.append("pack and against must be packs of the function")
    except Refused as e:
        bad.append(str(e))
    try:
        for d in rec["groups"].values():
            for r in d["measures"].values():
                for k in ("ci95", "base_ci95") + (("gain_ci95",) if rec["schema"] >= 2 else ()):
                    if r[k] is not None and not (len(r[k]) == 2 and r[k][0] <= r[k][1]):
                        bad.append("an interval is not [low, high]")
        out = outcomes(rec["groups"])
        if not rec["groups"]:
            bad.append("no groups")
        if out != {"better": rec["better"], "worse": rec["worse"]}:
            bad.append("better and worse are not what the intervals give")
        if rec["kind"] == "improve" and not out["better"]:
            bad.append("kind improve needs at least one measure that is better; use kind measure")
        if rec["kind"] == "replicate" and rec["pack"] != rec["against"]:
            bad.append("kind replicate compares a pack with itself")
        if rec["kind"] == "replicate":
            off = ["%s: %s" % (g, m) for g, d in rec["groups"].items() for m, r in d["measures"].items()
                   if not math.isclose(r["value"], r["base_value"], rel_tol=RERUN_TOLERANCE, abs_tol=1e-9)]
            if off:
                bad.append("not a replication, these differ (use kind measure): " + ", ".join(off))
    except (AttributeError, KeyError, TypeError, IndexError):
        bad.append("groups are malformed")
    return bad


def rerun_errors(rec, jobs=None):
    """Measure again on this checkout; the record's values and its base must both hold."""
    bad = []
    if rec["schema"] == 1:
        return []       # measured with the earlier overlap rule and measure list; its form is checked
    main_ref = "origin/main" if git("rev-parse", "--verify", "--quiet", "origin/main") else "HEAD"
    if git("merge-base", "--is-ancestor", rec["base"], main_ref) is None:
        return ["base %s is not a commit of main" % rec["base"][:12]]
    try:
        old = committed(rec["function"], rec["against"], rec["base"])
    except Refused as e:
        return [str(e)]
    got = compare(old, measure(rec["function"], rec["pack"], jobs), rec["function"])
    if set(got) != set(rec["groups"]):
        return ["the groups are not the ones the tool measures"]
    for g in got:
        if set(got[g]["measures"]) != set(rec["groups"][g]["measures"]):
            bad.append("%s: the measures are not the ones the tool gives" % g)
            continue
        for m, r in got[g]["measures"].items():
            want = rec["groups"][g]["measures"][m]
            if r["base_value"] != want["base_value"] or r["base_ci95"] != want["base_ci95"]:
                bad.append("%s %s: the base is not what is committed at %s" % (g, m, rec["base"][:12]))
            pairs = [(r["value"], want["value"])] + list(zip(r["ci95"] or [], want["ci95"] or [])) \
                + list(zip(r.get("gain_ci95") or [], want.get("gain_ci95") or []))
            if any(not math.isclose(x, y, rel_tol=RERUN_TOLERANCE, abs_tol=1e-9)
                   for x, y in pairs) or bool(r["ci95"]) != bool(want["ci95"]) \
                    or bool(r.get("gain_ci95")) != bool(want.get("gain_ci95")):
                bad.append("%s %s: measured %.6g, recorded %.6g" % (g, m, r["value"], want["value"]))
    return bad


def cmd_status():
    import adapters
    have = sorted(p for p in os.listdir(os.path.join(ROOT, "packs")) if os.path.isdir(os.path.join(ROOT, "packs", p)))
    measured = {"correlate": adapters.PACKS, **fb.PACKS}
    for f, packs in measured.items():
        mine = [p for p in have if p.startswith(f + "-")]
        print("%-10s %d of %d packs measured%s" % (f, len(set(packs) & set(mine)), len(mine),
              "; held-out set too" if f == "correlate" else "; no held-out set"))
        for p in mine:
            if p not in packs:
                print("           not measured: %s (%s)" % (p, fb.NOT_COVERED.get(p, "no case written")))
    recs = sorted(f for f in os.listdir(REVIEWS) if f.endswith(".json"))
    print("\n%d records in reviews/" % len(recs))
    for f in recs:
        with open(os.path.join(REVIEWS, f), encoding="utf-8") as fh:
            r = json.load(fh)
        print("  %-30s %-10s %s: %d better, %d worse" % (f[:-5], r["kind"], r["pack"], len(r["better"]), len(r["worse"])))


def cmd_measure(a):
    f, against = function_of(a.pack), a.against or a.pack
    if function_of(against) != f:
        raise Refused("%s and %s are packs of different functions" % (a.pack, against))
    path = os.path.join(REVIEWS, a.slug + ".json") if a.cmd == "record" else None
    if path and os.path.exists(path):
        raise Refused("%s exists; a record is never rewritten, choose another slug" % os.path.relpath(path, ROOT))
    base = base_commit(a.base)
    groups = compare(committed(f, against, base), measure(f, a.pack, a.jobs), f)
    show(a.pack, against, groups, getattr(a, "group", None))
    if not path:
        return
    rec = {"schema": SCHEMA, "slug": a.slug, "kind": a.kind, "function": f, "pack": a.pack, "against": against,
           "base": base, "set": "tuning", "question": a.question, "finding": a.finding,
           "environment": {"python": platform.python_version(), "system": platform.system(),
                           "machine": platform.machine()},
           "groups": groups, **outcomes(groups)}
    rec = json.loads(json.dumps(rec))
    bad = errors_in(rec, a.slug)
    if bad:
        raise Refused("not written: " + "; ".join(bad))
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
        fh.write("\n")
    print("wrote %s" % os.path.relpath(path, ROOT))


def cmd_check(a):
    files = a.files or sorted(os.path.join(REVIEWS, f) for f in os.listdir(REVIEWS) if f.endswith(".json"))
    failed = 0
    for path in files:
        slug = os.path.basename(path)[:-5]
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
            bad = errors_in(rec, slug)
            if not bad and a.rerun:
                bad = rerun_errors(rec, a.jobs)
        except (OSError, ValueError) as e:
            bad = [str(e)]
        print("%s: %s" % (slug, "ok" if not bad else "; ".join(bad)))
        failed += bool(bad)
    print("%d records checked, %d failed" % (len(files), failed))
    return 1 if failed else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    t, r, c = sub.add_parser("try"), sub.add_parser("record"), sub.add_parser("check")
    r.add_argument("slug")
    for p in (t, r):
        p.add_argument("pack")
        p.add_argument("--against")
        p.add_argument("--base")
        p.add_argument("--jobs", type=int)
    t.add_argument("--group")
    r.add_argument("--kind", required=True, choices=KINDS)
    r.add_argument("--question", required=True)
    r.add_argument("--finding", required=True)
    c.add_argument("--rerun", action="store_true")
    c.add_argument("--jobs", type=int)
    c.add_argument("files", nargs="*")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "status":
            return cmd_status()
        return cmd_check(a) if a.cmd == "check" else cmd_measure(a)
    except Refused as e:
        print("refused: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
