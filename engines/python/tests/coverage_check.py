"""Line coverage of the engine (src/), standard library only.

    PYTHONPATH=src python3 tests/coverage_check.py [--floor PCT] [--src DIR] [--tests DIR] [--files]

Runs the unittest suite (discover -s tests) with a line monitor on, and
reports, per source file and in total, the executable lines (those that
have bytecode: every line `co_lines()` names in the file's code objects)
and the ones that ran. Python 3.12 and later use sys.monitoring (each line
is reported once, then its event is disabled, so the suite runs at nearly
full speed); earlier versions use sys.settrace. Exit status 1 when a test
fails or the total is below --floor."""

import argparse
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def executable_lines(path):
    with open(path, encoding="utf-8") as f:
        code = compile(f.read(), path, "exec")
    lines = set()
    todo = [code]
    while todo:
        c = todo.pop()
        for _, _, line in c.co_lines():
            if line is not None and line > 0:
                lines.add(line)
        todo.extend(k for k in c.co_consts if isinstance(k, types.CodeType))
    return lines


def source_files(src):
    out = []
    for d, _, files in os.walk(src):
        for f in files:
            if f.endswith(".py"):
                out.append(os.path.abspath(os.path.join(d, f)))
    return sorted(out)


class Monitor:
    def __init__(self, src):
        self.src = os.path.abspath(src) + os.sep
        self.hits = {}

    def _hit(self, filename, line):
        if filename.startswith(self.src):
            self.hits.setdefault(filename, set()).add(line)

    def start(self):
        mon = getattr(sys, "monitoring", None)
        if mon is not None:
            self.tool = mon.COVERAGE_ID
            mon.use_tool_id(self.tool, "goat-coverage")

            def on_line(code, line):
                self._hit(code.co_filename, line)
                return mon.DISABLE
            mon.register_callback(self.tool, mon.events.LINE, on_line)
            mon.set_events(self.tool, mon.events.LINE)
        else:  # pragma: no cover - Python before 3.12
            def tracer(frame, event, arg):
                if event == "line":
                    self._hit(frame.f_code.co_filename, frame.f_lineno)
                return tracer
            sys.settrace(tracer)
            import threading
            threading.settrace(tracer)

    def stop(self):
        mon = getattr(sys, "monitoring", None)
        if mon is not None:
            mon.set_events(self.tool, 0)
            mon.register_callback(self.tool, mon.events.LINE, None)
            mon.free_tool_id(self.tool)
        else:  # pragma: no cover
            sys.settrace(None)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--floor", type=float, default=0.0)
    ap.add_argument("--src", default=os.path.join(HERE, "..", "src"))
    ap.add_argument("--tests", default=HERE)
    ap.add_argument("--files", action="store_true", help="list the lines not run, per file")
    args = ap.parse_args(argv)

    monitor = Monitor(args.src)
    monitor.start()
    sys.path.insert(0, os.path.abspath(args.tests))
    suite = unittest.defaultTestLoader.discover(args.tests, top_level_dir=args.tests)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    monitor.stop()

    total = ran = 0
    rows = []
    for path in source_files(args.src):
        lines = executable_lines(path)
        hit = monitor.hits.get(path, set()) & lines
        total += len(lines)
        ran += len(hit)
        rows.append((os.path.relpath(path, args.src), len(lines), len(hit), sorted(lines - hit)))
    width = max(len(r[0]) for r in rows)
    print("\n%-*s %6s %6s %7s" % (width, "file", "lines", "run", "cover"))
    for name, n, h, missed in rows:
        print("%-*s %6d %6d %6.1f%%" % (width, name, n, h, 100.0 * h / n if n else 100.0))
        if args.files and missed:
            print("    not run: %s" % ", ".join(map(str, missed)))
    pct = 100.0 * ran / total if total else 100.0
    print("%-*s %6d %6d %6.1f%%" % (width, "TOTAL", total, ran, pct))
    if not result.wasSuccessful():
        print("coverage: tests failed")
        return 1
    if pct < args.floor:
        print("coverage: %.1f%% is below the floor of %.1f%%" % (pct, args.floor))
        return 1
    print("coverage: %.1f%% (floor %.1f%%)" % (pct, args.floor))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
