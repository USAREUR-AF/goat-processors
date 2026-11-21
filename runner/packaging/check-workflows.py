"""Checks, before any tag, what a workflow step needs from the job it is in.

For every job of the given GitHub workflow files:
  - a script from this repository that a step runs (runner/..., tools/...,
    packs/... ending in .sh, .py or .mjs) must exist, and the job must check
    the repository out (actions/checkout) in an earlier step;
  - a step that reads dist/ must come after a step that fills it: an
    actions/download-artifact, or a step that runs build-deb.sh.
A release step placed in a job without a checkout fails only when a tag
runs it; this finds it on the pull request.

  python3 -I runner/packaging/check-workflows.py .github/workflows/*.yml
  python3 -I runner/packaging/check-workflows.py --self-test
"""
import os
import re
import sys

import yaml

SCRIPT = re.compile(r"(?<![\w./-])((?:runner|tools|packs)/[\w./-]+\.(?:sh|py|mjs))\b")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def problems(name, doc, root=ROOT):
    out = []
    for job_id, job in (doc.get("jobs") or {}).items():
        checked_out = False
        dist_filled = False
        for n, step in enumerate(job.get("steps") or [], 1):
            uses = step.get("uses", "") or ""
            run = step.get("run", "") or ""
            where = "%s: job %s, step %d (%s)" % (name, job_id, n, step.get("name") or uses or run.strip().splitlines()[0][:50])
            for path in SCRIPT.findall(run):
                if not checked_out:
                    out.append("%s runs %s, but the job has no actions/checkout before it" % (where, path))
                if not os.path.exists(os.path.join(root, path)):
                    out.append("%s runs %s, which is not in the repository" % (where, path))
            if re.search(r"(?<![\w/])dist/", run) and not dist_filled and "build-deb.sh" not in run:
                out.append("%s reads dist/, but nothing in the job fills it before (download-artifact or build-deb.sh)" % where)
            if uses.startswith("actions/checkout@"):
                checked_out = True
            if uses.startswith("actions/download-artifact@") or "build-deb.sh" in run:
                dist_filled = True
    return out


def self_test():
    broken = yaml.safe_load(
        """
jobs:
  image-index:
    steps:
      - uses: sigstore/cosign-installer@x
      - run: runner/packaging/check-glibc.sh 2.35 dist/*.deb
  release:
    steps:
      - uses: actions/checkout@x
      - uses: actions/download-artifact@x
      - run: runner/packaging/check-glibc.sh 2.35 dist/*.deb
      - run: runner/packaging/no-such-script.sh
"""
    )
    got = problems("t.yml", broken)
    want = ["job image-index, step 2", "no actions/checkout", "reads dist/", "no-such-script.sh, which is not in the repository"]
    ok = len(got) == 3 and all(any(w in g for g in got) for w in want) and not any("job release, step 3" in g for g in got)
    print("check-workflows self-test:", "passed" if ok else "FAILED")
    for g in got:
        print("  " + g)
    return 0 if ok else 1


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if not argv:
        print(__doc__)
        return 2
    found = []
    for f in argv:
        with open(f) as fh:
            found += problems(os.path.relpath(f, ROOT), yaml.safe_load(fh))
    for p in found:
        print("FAIL: " + p)
    print("check-workflows: %d file(s), %d problem(s)" % (len(argv), len(found)))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
