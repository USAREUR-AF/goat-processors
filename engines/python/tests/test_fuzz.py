"""Fuzzing of the input parsers: every function's pack.def parser and the
steps-file JSON reader (io.parse_steps), and the engines' report intake.

A seeded generator written here mutates the shipped packs, the load vectors
and the scenario vectors (delete, repeat, swap and corrupt tokens and lines,
odd numbers, control and non-ASCII characters, deep nesting) and makes
random text. The property: a parser either returns or raises its own error
(PackError, StepsError); never another exception. Bounded: a fixed number of
cases per parser and a time budget (GOAT_FUZZ_SECONDS, default 4 s per
parser), so a CI run takes seconds; GOAT_FUZZ_CASES raises the count for a
long local run."""

import json
import os
import random
import time
import unittest

from goat_core import FUNCTIONS, PackError
from goat_core.io import StepsError, parse_steps
from vectorlib import ROOT, load_json, load_vector_files, vector_files

SEED = int(os.environ.get("GOAT_FUZZ_SEED", "20261120"))
CASES = int(os.environ.get("GOAT_FUZZ_CASES", "1500"))
SECONDS = float(os.environ.get("GOAT_FUZZ_SECONDS", "4"))

ODD_TOKENS = [
    "", "=", "==", "x=", "=1", "-", "-0", "+1", "1e3", "1E-3", ".5", "5.", "1_0", "0x10", "inf", "-inf",
    "nan", "NaN", "Infinity", "1e999", "-1e999", "9" * 30, "9" * 5000, "0." + "0" * 400 + "1",
    "١٢", "１", " ", "\t", "#", "a#b", "\x00", "\x7f", " ", "é", "🦊",
    "true", "null", "[]", "{}", "-1", "0", "1", "2", "100000000000000000000",
]


NUMBERS = ["9" * 5000, "1" + "0" * 4400, "-" + "9" * 4301, "0." + "9" * 5000, "1e999", "-0", "+1", "1_000",
           "\u0661\u0662", "\uff11", "0x1f", "1e3", ".5", "5.", "nan", "inf", "-1", "0", "18446744073709551616",
           "9223372036854775808", "9223372036854775807", "4.9e-324", "1.7976931348623157e308"]


def _pack_texts():
    texts = []
    packs = os.path.join(ROOT, "packs")
    for name in sorted(os.listdir(packs)):
        with open(os.path.join(packs, name, "pack.def"), encoding="utf-8") as f:
            texts.append((name.split("-", 1)[0], f.read()))
    for function in FUNCTIONS:
        for f in load_vector_files(function):
            texts.append((function, load_json(f)["pack_def"]))
    return texts


def _tokens(text):
    out = []
    for line in text.split("\n"):
        out.append(line.split(" "))
    return out


def _join(lines):
    return "\n".join(" ".join(t) for t in lines)


def mutate_text(rng, text, corpus_tokens):
    """One random mutation of a line-oriented text."""
    lines = _tokens(text)
    for _ in range(rng.randint(1, 4)):
        op = rng.randrange(12)
        if not lines:
            lines = [[]]
        li = rng.randrange(len(lines))
        line = lines[li]
        if op == 0:
            del lines[li]
        elif op == 1:
            lines.insert(rng.randrange(len(lines) + 1), list(line))
        elif op == 2 and len(lines) > 1:
            lj = rng.randrange(len(lines))
            lines[li], lines[lj] = lines[lj], lines[li]
        elif op == 3 and line:
            del line[rng.randrange(len(line))]
        elif op == 4:
            line.insert(rng.randrange(len(line) + 1), rng.choice(ODD_TOKENS))
        elif op == 5 and line:
            ti = rng.randrange(len(line))
            tok = line[ti]
            if "=" in tok:
                k, _ = tok.split("=", 1)
                line[ti] = k + "=" + rng.choice(ODD_TOKENS)
            else:
                line[ti] = rng.choice(ODD_TOKENS + corpus_tokens)
        elif op == 6:
            line.insert(rng.randrange(len(line) + 1), rng.choice(corpus_tokens))
        elif op == 7:
            lines.insert(rng.randrange(len(lines) + 1),
                         [rng.choice(corpus_tokens) for _ in range(rng.randint(1, 5))])
        elif op == 8:
            s = _join(lines)
            if s:
                i = rng.randrange(len(s))
                s = s[:i] + rng.choice(["\r", "\r\n", "\t", "  ", "\x0b", "\x0c", "\x1c", "\x85", "#", "="]) + s[i:]
            lines = _tokens(s)
        elif op == 9:
            s = _join(lines)
            if s:
                i, j = sorted((rng.randrange(len(s)), rng.randrange(len(s))))
                s = s[:i] + s[j:]
            lines = _tokens(s)
        else:
            # a number of the text (a token or a parameter value with a digit) made odd
            spots = [(a, b) for a, l in enumerate(lines) for b, t in enumerate(l)
                     if any(c.isdigit() for c in t)]
            if spots:
                a, b = rng.choice(spots)
                tok = lines[a][b]
                odd = rng.choice(NUMBERS)
                lines[a][b] = tok.split("=", 1)[0] + "=" + odd if "=" in tok else odd
    return _join(lines)


def random_text(rng):
    alphabet = "abcdefghijklmnopqrstuvwxyz_=.-+0123456789 \t\n\r#é \x00"
    return "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 200)))


class PackDefFuzz(unittest.TestCase):
    def test_parsers_raise_only_pack_error(self):
        texts = _pack_texts()
        corpus = sorted({t for _, text in texts for line in _tokens(text) for t in line if t})
        for function, fn in FUNCTIONS.items():
            rng = random.Random("%d-%s" % (SEED, function))
            own = [t for f, t in texts if f == function]
            others = [t for f, t in texts if f != function]
            loaded = refused = 0
            deadline = time.monotonic() + SECONDS
            for n in range(CASES):
                if time.monotonic() > deadline:
                    break
                r = rng.random()
                if r < 0.8:
                    text = mutate_text(rng, rng.choice(own), corpus)
                elif r < 0.9:
                    text = mutate_text(rng, rng.choice(others), corpus)
                else:
                    text = random_text(rng)
                try:
                    fn.parse_pack(text)
                    loaded += 1
                except PackError:
                    refused += 1
                except Exception as e:  # pragma: no cover - a finding
                    self.fail("%s parse_pack raised %s: %r\n--- pack.def (first 2000 characters) ---\n%s"
                              % (function, type(e).__name__, str(e)[:200], text[:2000]))
            with self.subTest(function=function):
                self.assertGreater(loaded + refused, 100)
                self.assertGreater(refused, 0)


def _nest(depth):
    return "[" * depth + "]" * depth


class StepsFuzz(unittest.TestCase):
    def test_json_reader_raises_only_steps_error(self):
        rng = random.Random("%d-steps" % SEED)
        docs = [json.dumps(load_json(f)) for fn in FUNCTIONS for f in vector_files(fn)[:6]]
        specials = ['{"steps": %s}' % _nest(100000), _nest(100000), '{"steps": [' + "1" * 5000 + "]}",
                    '{"steps": [{"tick": 1}], "steps": 3}', "", " ", "﻿{}", '{"steps": NaN}',
                    '{"steps": [{"ingest": {}}, {"tick": -1}, {}]}', '{"steps": "x"}', "[]", "null"]
        for text in specials:
            self._one(text)
        deadline = time.monotonic() + SECONDS
        for n in range(CASES):
            if time.monotonic() > deadline:
                break
            s = rng.choice(docs)
            for _ in range(rng.randint(1, 5)):
                if not s:
                    break
                i = rng.randrange(len(s))
                op = rng.randrange(4)
                if op == 0:
                    s = s[:i] + s[i + rng.randint(1, 20):]
                elif op == 1:
                    s = s[:i] + rng.choice(['"', "{", "}", "[", "]", ",", ":", "\\", "\\u12", "1e999",
                                            "-", "\x00", "é", "null", "true"]) + s[i:]
                elif op == 2:
                    j = rng.randrange(len(s))
                    s = s[:i] + s[j:j + 30] + s[i:]
                else:
                    s = s[:i]
            self._one(s)

    def _one(self, text):
        try:
            steps = parse_steps(text)
        except StepsError:
            return
        except Exception as e:  # pragma: no cover - a finding
            self.fail("parse_steps raised %s: %r on %r" % (type(e).__name__, e, text[:200]))
        self.assertIsInstance(steps, list)
        for s in steps:
            self.assertTrue("ingest" in s or "tick" in s)


# The intake fuzz keeps numbers to magnitudes the spec's arithmetic handles:
# a position predicted 1e15 degrees away (a large speed or time step, or any
# east motion at a pole, where cos(lat) is 6e-17) makes the frame's wrap
# ("adding or subtracting 360") loop for hours, and a number whose square overflows
# binary64 makes the filter's variances infinite (DISAGREEMENTS.md, "Huge
# numbers in a report"). Wrong types, nulls, odd strings and every key are
# fuzzed without limit.
OTHER_VALUES = [None, True, False, "", "x", "radar", "a-f-A-M-F", "a-h-S", "coherent", "drifting",
                "free-running", [], [1], {}, {"a": 1}, ["m"]]
VALUES = OTHER_VALUES + [0, 1, -1, 1.5, -0.0, 0.001, 1e6, -1e6, 359.9, -720.5]
TIME_VALUES = OTHER_VALUES + [0, 1, -1, 999, 60000, -60000, 10 ** 9, 1.5, 2 ** 63, -(2 ** 63) - 1]
POSITION_VALUES = OTHER_VALUES + [0, 1, -1, 1.5, -0.0, 89.0, -89.0, 180.0, -180.0, 359.9, -720.5]
VALUES_OF = {"lat": POSITION_VALUES, "lon": POSITION_VALUES, "stale_ms": TIME_VALUES,
             "received_ms": TIME_VALUES}
KEYS = ["track.source_id", "uid", "time_ms", "lat", "lon", "hae", "ce", "course", "speed_ms", "type",
        "stale_ms", "time_error_ms", "time_state", "received_ms", "fuse.group", "quality.marks",
        "track.simulated", "other"]


def random_report(rng, base):
    r = dict(base)
    for _ in range(rng.randint(0, 4)):
        k = rng.choice(KEYS)
        if rng.random() < 0.2:
            r.pop(k, None)
        else:
            if k == "time_ms":
                # within a day of the base report, or of another type
                r[k] = rng.choice([base.get("time_ms", 0) + rng.randint(-3600000, 86400000)] + OTHER_VALUES)
            else:
                r[k] = rng.choice(VALUES_OF.get(k, VALUES))
    return r


class IntakeFuzz(unittest.TestCase):
    """Any JSON report and any integer tick: the engine returns events and
    trace (lists), never raises."""

    def test_engines_take_any_report(self):
        for function, fn in FUNCTIONS.items():
            rng = random.Random("%d-intake-%s" % (SEED, function))
            files = vector_files(function)
            deadline = time.monotonic() + SECONDS
            n = 0
            while n < CASES // 3 and time.monotonic() < deadline:
                v = load_json(rng.choice(files))
                eng = fn.open(os.path.join(ROOT, "packs", v["pack"]))
                ingests = [s["ingest"] for s in v["steps"] if "ingest" in s]
                t = 0
                for _ in range(rng.randint(1, 25)):
                    n += 1
                    if rng.random() < 0.2:
                        t = rng.choice(ingests).get("time_ms", 0) + rng.randint(-1000, 600000)
                        t = t if isinstance(t, int) else 0
                        out = eng.tick(t)
                    else:
                        report = random_report(rng, rng.choice(ingests))
                        try:
                            out = eng.ingest(report)
                        except Exception as e:  # pragma: no cover - a finding
                            self.fail("%s ingest raised %s: %r on %r" % (function, type(e).__name__, e, report))
                    self.assertIsInstance(out[0], list)
                    self.assertIsInstance(out[1], list)
                eng.snapshot()


if __name__ == "__main__":
    unittest.main()
