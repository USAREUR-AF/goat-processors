"""Sets the volume budget from a run, and keeps the README's table equal to it.

  python3 -I runner/volume/budget.py runner/target/volume/results.json
      rewrites runner/volume/budget.json for every size in the results
      (measured figures and ceilings) and the "Measured" table of
      runner/README.md, "Output volume". Other sizes are kept.
  python3 -I runner/volume/budget.py --check
      exits 1 when the README table differs from budget.json (CI).

Ceilings, from the measured figure m (the same rules for every size):
  fabric bytes per report      m x 1.25, rounded up to the next 10
  fabric values per s          m x 1.25, rounded up to the next 0.5
  fabric bytes per s           m x 1.25, rounded up to the next 1000
  quality bytes per value      m x 1.25, rounded up to the next 1000
  disk MB per input hour       m x 1.25, rounded up to the next 10
  peak memory MB               m x 1.5, rounded up to the next 50
  wall s                       m x 4, rounded up to the next 10, at least 30
Fabric and disk figures are the same on every run of the same input, so a
quarter is room for small changes; memory and time depend on the machine.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUNNER = os.path.dirname(HERE)
BUDGET = os.path.join(HERE, "budget.json")
README = os.path.join(RUNNER, "README.md")
BEGIN = "<!-- volume table: written by runner/volume/budget.py from volume/budget.json -->"
END = "<!-- end of volume table -->"

RULES = {
    "fabric_bytes_per_report": (1.25, 10, 0),
    "fabric_values_per_s": (1.25, 0.5, 0),
    "fabric_bytes_per_s": (1.25, 1000, 0),
    "quality_bytes_per_value": (1.25, 1000, 0),
    "disk_mb_per_input_hour": (1.25, 10, 0),
    "peak_rss_mb": (1.5, 50, 0),
    "wall_s": (4, 10, 30),
}

ABOUT = (
    "Ceilings of the volume test (runner/tests/volume.rs): N objects seen by a radar and a beacon for "
    "120 s of input (runner/volume/scenario.py), correlate-assign-time then quality-feed, at the shipped "
    "defaults. Written by runner/volume/budget.py from a run's target/volume/results.json; its docstring "
    "gives the rule for each ceiling. 'measured' is that run. To raise a ceiling, run the test, run "
    "budget.py on the results (it rewrites this file and the README table), and say in the commit message "
    "which figure rose and why."
)


def ceiling(name, m):
    k, step, floor = RULES[name]
    return max(floor, math.ceil(m * k / step - 1e-9) * step)


def num(n):
    return "{:,}".format(int(round(n))).replace(",", " ")


def size(nbytes):
    for unit, d in (("GB", 1e9), ("MB", 1e6), ("KB", 1e3)):
        if nbytes >= d:
            v = nbytes / d
            return ("%.1f %s" % (v, unit)) if v < 10 else ("%d %s" % (round(v), unit))
    return "%d B" % nbytes


def rows(budget):
    out = [
        "| Objects | Reports | Fabric values per input second | Fabric bytes per input report | Fabric bytes per input second | Bytes per `quality` value | Trace records, largest step | Peak memory | Disk per input hour | Time for %d s of input |" % budget["seconds"],
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for n in sorted(budget["sizes"], key=int):
        m = budget["sizes"][n]["measured"]
        behind = m["wall_s"] > budget["seconds"]
        out.append("| %s | %s | %.1f | %s | %s | %s | %s | %s | %s | %s s |" % (
            n + (" (falls behind)" if behind else ""),
            num(m["reports"]),
            m["fabric_values_per_s"],
            num(m["fabric_bytes_per_report"]),
            size(m["fabric_bytes_per_s"]),
            size(m["quality_bytes_per_value"]),
            num(m["trace_max_step"]),
            size(m["peak_rss_mb"] * 1048576),
            size(m["disk_mb_per_input_hour"] * 1048576),
            num(m["wall_s"]),
        ))
    return "\n".join(out)


def table_in(text):
    a, b = text.find(BEGIN), text.find(END)
    if a < 0 or b < a:
        sys.exit("runner/README.md has no volume table markers (%s ... %s)" % (BEGIN, END))
    return a + len(BEGIN), b


def main(argv):
    with open(BUDGET) as f:
        budget = json.load(f)
    with open(README) as f:
        readme = f.read()
    a, b = table_in(readme)
    if argv == ["--check"]:
        want = "\n" + rows(budget) + "\n"
        if readme[a:b] != want:
            print("runner/README.md's volume table differs from runner/volume/budget.json; run python3 -I runner/volume/budget.py on a results file, or fix the table to:\n" + want)
            return 1
        print("volume table: README matches budget.json (%d sizes)" % len(budget["sizes"]))
        return 0
    if len(argv) != 1:
        print(__doc__)
        return 2
    with open(argv[0]) as f:
        results = json.load(f)
    if results["seconds"] != budget.get("seconds", results["seconds"]):
        sys.exit("the results are for %d s of input; the budget is for %d s" % (results["seconds"], budget["seconds"]))
    budget["about"] = ABOUT
    budget["seconds"] = results["seconds"]
    for r in results["runs"]:
        met = dict(r["metrics"])
        measured = {k: round(v, 1) for k, v in met.items()}
        measured.update({
            "reports": r["reports"],
            "trace_records": r["trace_records"],
            "trace_max_step": r["trace_max_step"],
            "input_bytes": r["input_bytes"],
            "outputs_file_per_input": round(r["file_bytes"] / max(1, r["input_bytes"]), 1),
            "values": {k: v["values"] for k, v in r["keys"].items()},
        })
        entry = {name: ceiling(name, met[name]) for name in RULES}
        entry["measured"] = measured
        budget["sizes"][str(r["objects"])] = entry
    with open(BUDGET, "w") as f:
        f.write(json.dumps(budget, indent=1) + "\n")
    with open(README, "w") as f:
        f.write(readme[:a] + "\n" + rows(budget) + "\n" + readme[b:])
    print(rows(budget))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
