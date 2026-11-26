"""Writes runner/THIRD-PARTY.md: every crate the runner's Linux build uses,
with its version, license and source, from Cargo.lock through cargo.

    python3 -I runner/packaging/third-party.py          # write
    python3 -I runner/packaging/third-party.py --check  # exit 1 when the file is not current
"""
import json
import pathlib
import subprocess
import sys

RUNNER = pathlib.Path(__file__).resolve().parent.parent
OUT = RUNNER / "THIRD-PARTY.md"
# Patched copies of third-party crates (runner/vendor/README.md): they have no registry source.
VENDORED = {d.name for d in (RUNNER / "vendor").iterdir() if d.is_dir()}
TARGETS = ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"]


def used_ids():
    ids = set()
    for t in TARGETS:
        out = subprocess.run(
            ["cargo", "tree", "--locked", "--target", t, "-e", "normal,build", "--prefix", "none", "--format", "{p}"],
            cwd=RUNNER, check=True, capture_output=True, text=True).stdout
        for line in out.splitlines():
            parts = line.replace(" (*)", "").split()
            if len(parts) >= 2:
                ids.add((parts[0], parts[1].lstrip("v")))
    return ids


def main():
    meta = json.loads(subprocess.run(["cargo", "metadata", "--locked", "--format-version", "1"],
                                     cwd=RUNNER, check=True, capture_output=True, text=True).stdout)
    used = used_ids()
    rows = sorted((p["name"], p["version"], (p.get("license") or "see the crate").strip(), p.get("repository") or "")
                  for p in meta["packages"] if (p["source"] or p["name"] in VENDORED) and (p["name"], p["version"]) in used)
    lines = [
        "<!-- Written by runner/packaging/third-party.py from Cargo.lock. Do not edit. -->",
        "# Third-party crates in the runner",
        "",
        "The runner (`runner/`) is built from these crates, each at the exact version",
        "`runner/Cargo.lock` pins. The engines use none of them. `cargo deny check`",
        "(`runner/deny.toml`) and `cargo audit` run on them in CI.",
        "",
        f"{len(rows)} crates, for the Linux targets {', '.join(TARGETS)}.",
        "",
        "| Crate | Version | License | Source |",
        "|---|---|---|---|",
    ]
    lines += [f"| {n} | {v} | {l} | {r} |" for n, v, l, r in rows]
    text = "\n".join(lines) + "\n"
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != text:
            print("runner/THIRD-PARTY.md is not current: run python3 -I runner/packaging/third-party.py")
            return 1
        return 0
    OUT.write_text(text)
    print(f"wrote {OUT} ({len(rows)} crates)")
    return 0


sys.exit(main())
