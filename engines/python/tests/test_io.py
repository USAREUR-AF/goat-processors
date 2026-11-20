"""Unit tests of goat_core.io: the steps file, the events file and the
runner (tools/perf/README.md, Runner contract), in process and through
runner/run."""

import contextlib
import io as _io
import json
import os
import subprocess
import tempfile
import unittest

from goat_core import FUNCTIONS
from goat_core import io as gio
from vectorlib import ROOT, load_json, pack_dir, vector_files

RUN = os.path.join(ROOT, "engines", "python", "runner", "run")


class Steps(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(gio.parse_steps('{"steps": [{"tick": 1}, {"ingest": {}, "expect": 3}], "x": 1}'),
                         [{"tick": 1}, {"ingest": {}, "expect": 3}])
        self.assertEqual(gio.parse_steps('{"steps": []}'), [])
        for bad in ("", "{", "[]", '{"steps": 1}', '{"steps": [1]}', '{"steps": [{"name": "x"}]}', '"x"'):
            with self.assertRaises(gio.StepsError):
                gio.parse_steps(bad)

    def test_read_missing_file(self):
        with self.assertRaises(gio.StepsError):
            gio.read_steps("/nonexistent/steps.json")

    def test_run_steps_and_events_file(self):
        v = load_json(vector_files("filter")[0])
        eng = FUNCTIONS["filter"].open(pack_dir(v["pack"]))
        outputs, snap = gio.run_steps(eng, v["steps"])
        self.assertEqual(len(outputs), len(v["steps"]))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "events.jsonl")
            gio.write_events(path, outputs, snap, True)
            lines = [json.loads(l) for l in open(path, encoding="utf-8")]
            self.assertEqual(lines[0]["step"], 0)
            self.assertIn("trace", lines[0])
            self.assertEqual(lines[-1], {"snapshot": snap})
            gio.write_events(path, outputs, snap, False)
            self.assertNotIn("trace", json.loads(open(path, encoding="utf-8").readline()))


class Main(unittest.TestCase):
    def call(self, argv):
        out, err = _io.StringIO(), _io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gio.main(argv, FUNCTIONS)
        return code, out.getvalue(), err.getvalue()

    def test_counters(self):
        f = vector_files("fuse")[0]
        v = load_json(f)
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, "e.jsonl")
            code, out, err = self.call(["--function", "fuse", "--pack", pack_dir(v["pack"]), "--steps", f,
                                        "--events", ev, "--trace"])
            self.assertEqual(code, 0, err)
            c = json.loads(out)
            self.assertEqual(out.count("\n"), 1)
            self.assertEqual(list(c), ["engine", "function", "pack", "steps", "ingest", "tick", "events",
                                       "trace_records", "parse_ns", "load_ns", "run_ns"])
            self.assertEqual((c["engine"], c["function"], c["pack"]), ("python", "fuse", v["pack"]))
            self.assertEqual(c["steps"], len(v["steps"]))
            self.assertEqual(c["ingest"] + c["tick"], c["steps"])
            self.assertEqual(c["events"], sum(len(s["expect"]) for s in v["steps"]))
            self.assertEqual(c["trace_records"], sum(len(s["trace"]) for s in v["steps"]))
            self.assertEqual(len(open(ev, encoding="utf-8").readlines()), len(v["steps"]) + 1)

    def test_errors(self):
        f = vector_files("fuse")[0]
        self.assertEqual(self.call(["--function", "nope", "--pack", "x", "--steps", f])[0], 2)
        self.assertEqual(self.call(["--pack", "x"])[0], 2)
        self.assertEqual(self.call(["--function", "fuse", "--pack", "x", "--steps", f, "--bogus"])[0], 2)
        self.assertEqual(self.call(["--function", "fuse", "--pack", "/nonexistent", "--steps", f])[0], 1)
        self.assertEqual(self.call(["--function", "fuse", "--pack", pack_dir("fuse-best"),
                                    "--steps", "/nonexistent"])[0], 1)
        code, out, _ = self.call(["--function", "fuse", "--pack", pack_dir("fuse-best"), "--steps", f])
        self.assertEqual(code, 0)


class Script(unittest.TestCase):
    def test_runner_script(self):
        f = vector_files("quality")[0]
        v = load_json(f)
        p = subprocess.run([RUN, "--function", "quality", "--pack", pack_dir(v["pack"]), "--steps", f],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["steps"], len(v["steps"]))
        build = os.path.join(os.path.dirname(RUN), "build")
        self.assertEqual(subprocess.run([build]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
