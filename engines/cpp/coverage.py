"""Line coverage of the C++ engine's sources (engines/cpp/src), from gcc's
own coverage support: a build with -DGOAT_COVERAGE=ON (--coverage), the
tests run by ctest, then gcov's JSON output of every .gcda file. A line of
a header compiled into several objects counts as covered when any object
covers it. Python standard library only.

usage: python3 -I coverage.py BUILD_DIR [--floor PERCENT]

Prints one line per source file and the total; exits 1 when the total is
below the floor.
"""

import argparse
import gzip
import json
import pathlib
import subprocess
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("build")
    ap.add_argument("--floor", type=float, default=0.0)
    args = ap.parse_args()
    src = (pathlib.Path(__file__).resolve().parent / "src").as_posix() + "/"
    build = pathlib.Path(args.build).resolve()
    lines: dict[str, dict[int, bool]] = {}
    gcdas = sorted(build.rglob("*.gcda"))
    if not gcdas:
        print("coverage: no .gcda files under", build, file=sys.stderr)
        return 1
    for gcda in gcdas:
        out = subprocess.run(["gcov", "--json-format", "--stdout", gcda.name], cwd=gcda.parent,
                             capture_output=True, check=True).stdout
        for doc in out.splitlines():
            if not doc.strip():
                continue
            if doc[:2] == b"\x1f\x8b":
                doc = gzip.decompress(doc)
            for f in json.loads(doc)["files"]:
                name = f["file"]
                path = (gcda.parent / name).resolve().as_posix() if not name.startswith("/") else name
                path = pathlib.Path(path).resolve().as_posix()
                if not path.startswith(src):
                    continue
                seen = lines.setdefault(path[len(src):], {})
                for ln in f["lines"]:
                    no = ln["line_number"]
                    seen[no] = seen.get(no, False) or ln["count"] > 0
    total = covered = 0
    for name in sorted(lines):
        n, c = len(lines[name]), sum(lines[name].values())
        if n == 0:
            continue
        total, covered = total + n, covered + c
        print(f"{100.0 * c / n:6.1f}%  {c:5d}/{n:<5d} src/{name}")
    pct = 100.0 * covered / total
    print(f"{pct:6.1f}%  {covered:5d}/{total:<5d} total (floor {args.floor:.1f}%)")
    return 0 if pct >= args.floor else 1


if __name__ == "__main__":
    sys.exit(main())
