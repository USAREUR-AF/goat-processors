"""Checks of review.py. Run: python3 -I tools/review/test_review.py"""

import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import review as R  # noqa: E402


def record(**kw):
    rec = {"schema": 1, "slug": "a-test", "kind": "improve", "function": "filter", "pack": "filter-area",
           "against": "filter-area", "base": "0" * 40, "set": "tuning",
           "question": "Does the change keep more right reports?", "finding": "Yes, at every position error.",
           "environment": {"python": "3.12", "system": "Linux", "machine": "x86_64"},
           "groups": {"g": {"n": 30, "not_finished": 0, "measures": {
               "f1": {"value": 0.9, "ci95": [0.88, 0.92], "base_value": 0.8, "base_ci95": [0.78, 0.82]}}}},
           "better": ["g: f1"], "worse": []}
    rec.update(kw)
    return rec


class Verdicts(unittest.TestCase):
    def test_only_separated_intervals_count(self):
        self.assertEqual(R.verdict("f1", [0.7, 0.8], [0.81, 0.9]), "better")
        self.assertEqual(R.verdict("f1", [0.7, 0.8], [0.8, 0.9]), "no difference shown")
        self.assertEqual(R.verdict("swaps", [10, 20], [21, 30]), "worse")
        self.assertEqual(R.verdict("rms_m", [10, 20], [5, 9]), "better")
        self.assertEqual(R.verdict("nees", [10, 20], [1, 2]), "no difference shown")     # best is 1, not low
        self.assertEqual(R.verdict("f1", None, [0.8, 0.9]), "no difference shown")


class Records(unittest.TestCase):
    def test_a_good_record(self):
        self.assertEqual(R.errors_in(record(), "a-test"), [])

    def test_what_is_refused(self):
        hidden = copy.deepcopy(record())
        hidden["groups"]["g"]["measures"]["recall"] = {"value": .5, "ci95": [.4, .6], "base_value": .9,
                                                       "base_ci95": [.8, .95]}
        cases = [record(better=[]), hidden, record(set="evaluation"), record(question="why"),
                 record(pack="../x"), record(function="fuse"), record(kind="replicate"), record(base="main"),
                 record(environment={"python": "3", "system": "x", "machine": "y", "host": "z"}),
                 record(groups={}, better=[]), dict(record(), extra=1)]
        for rec in cases:
            self.assertTrue(R.errors_in(rec, "a-test"), rec)
        self.assertTrue(R.errors_in(record(), "another-name"))

    def test_a_replication_needs_equal_values_not_only_overlapping_intervals(self):
        m = {"value": 0.9, "ci95": [0.8, 0.95], "base_value": 0.9, "base_ci95": [0.8, 0.95]}
        rec = record(kind="replicate", better=[], groups={"g": {"n": 30, "not_finished": 0, "measures": {"f1": m}}})
        self.assertEqual(R.errors_in(rec, "a-test"), [])
        m["value"] = 0.89
        self.assertTrue(R.errors_in(rec, "a-test"))

    def test_a_pack_with_no_case_is_refused_with_the_reason(self):
        with self.assertRaises(R.Refused):
            R.function_of("filter-thin")


if __name__ == "__main__":
    unittest.main()
