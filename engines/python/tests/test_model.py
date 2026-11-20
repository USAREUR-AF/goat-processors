"""Unit tests of goat_core.model: reports and the frame (spec/correlate.md, Reports, Frame)."""

import math
import unittest

from goat_core import model


class Kinds(unittest.TestCase):
    def test_is_kind(self):
        self.assertTrue(model.is_kind("a", "str"))
        self.assertTrue(model.is_kind(3, "int"))
        self.assertFalse(model.is_kind(3.0, "int"))
        self.assertTrue(model.is_kind(3, "num"))
        self.assertTrue(model.is_kind(3.5, "num"))
        for kind in ("str", "int", "num"):
            self.assertFalse(model.is_kind(True, kind))
            self.assertFalse(model.is_kind(None, kind))
        self.assertFalse(model.is_kind("3", "num"))

    def test_missing_key_in_table_order(self):
        full = {"track.source_id": "s", "uid": "u", "time_ms": 1, "lat": 1.0, "lon": 2}
        self.assertIsNone(model.missing_key(full))
        self.assertEqual(model.missing_key({}), "track.source_id")
        self.assertEqual(model.missing_key(dict(full, uid=None, time_ms="x")), "uid")
        self.assertEqual(model.missing_key(dict(full, time_ms=1.0)), "time_ms")
        self.assertEqual(model.missing_key(dict(full, lat=True)), "lat")
        self.assertEqual(model.missing_key(dict(full, lon="2")), "lon")

    def test_normalize(self):
        r = {"track.source_id": "s", "hae": "x", "ce": 0, "course": 10, "speed_ms": None, "type": 5,
             "stale_ms": 1.5, "time_error_ms": -1, "time_state": "lost", "other": [1], "x": None}
        self.assertEqual(model.normalize(r), {"track.source_id": "s", "course": 10, "other": [1]})
        r2 = {"ce": 0.5, "time_error_ms": 0, "time_state": "drifting", "stale_ms": 7}
        self.assertEqual(model.normalize(r2), r2)
        self.assertNotIn("time_error_ms", model.normalize({"time_error_ms": float("inf")}))
        self.assertNotIn("time_error_ms", model.normalize({"time_error_ms": float("nan")}))
        src = {"ce": -1}
        model.normalize(src)
        self.assertEqual(src, {"ce": -1})  # a copy: the report is not changed

    def test_environment(self):
        self.assertEqual(model.environment({"type": "a-f-A-M-F"}), "A")
        self.assertIsNone(model.environment({"type": "a-f"}))
        self.assertIsNone(model.environment({}))


class Frame(unittest.TestCase):
    def test_wrap180(self):
        self.assertEqual(model.wrap180(180.0), 180.0)
        self.assertEqual(model.wrap180(-180.0), 180.0)
        self.assertEqual(model.wrap180(190.0), -170.0)
        self.assertEqual(model.wrap180(-540.0), 180.0)
        self.assertEqual(model.wrap180(0.0), 0.0)

    def test_plane_round_trip(self):
        ref = (48.0, 11.0)
        self.assertEqual(model.to_plane(ref, 48.0, 11.0), (0.0, 0.0))
        e, n = model.to_plane(ref, 48.01, 11.02)
        lat, lon = model.to_deg(ref, e, n)
        self.assertAlmostEqual(lat, 48.01, places=12)
        self.assertAlmostEqual(lon, 11.02, places=12)
        e, n = model.to_plane(ref, 48.0, 12.0)
        self.assertAlmostEqual(e, model.R * math.radians(1.0) * math.cos(math.radians(48.0)))
        self.assertEqual(n, 0.0)

    def test_across_the_dateline(self):
        ref = (0.0, 179.9)
        e, _ = model.to_plane(ref, 0.0, -179.9)
        self.assertGreater(e, 0)
        self.assertAlmostEqual(model.to_deg(ref, e, 0.0)[1], -179.9, places=9)

    def test_course_and_velocity(self):
        self.assertEqual(model.course_deg(0.0, 1.0), 0.0)
        self.assertEqual(model.course_deg(1.0, 0.0), 90.0)
        self.assertEqual(model.course_deg(-1.0, 0.0), 270.0)
        self.assertEqual(model.course_deg(0.0, -1.0), 180.0)
        self.assertEqual(model.course_deg(-0.0, 1.0), 0.0)
        ve, vn = model.velocity(90.0, 10.0)
        self.assertAlmostEqual(ve, 10.0)
        self.assertAlmostEqual(vn, 0.0)


if __name__ == "__main__":
    unittest.main()
