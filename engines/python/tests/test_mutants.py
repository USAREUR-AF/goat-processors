"""Tests written for the mutants that survived the vectors and are real
faults (tests/mutate.py; REFACTOR.md lists every survivor and why the rest
are equivalent). Each test names the mutant it kills.

Float thresholds are tested exactly: the engine computes a value once, the
pack's limit is set to exactly that value (repr round-trips binary64), and
the test checks the comparison the spec states (`<` or `<=`)."""

import math
import os
import unittest

from goat_core import FUNCTIONS, PackError, correlate, estimate, filter as F, fuse, gate, model, quality as Q
from goat_core.io import main
from goat_core.tracks import Track
from vectorlib import load_json, pack_dir, read_pack_def, run

FILT = "filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
CONFIRM = "pack t\nversion 1\n" + FILT + "confirm_count %d\nhold_failures 2\nstale_ms 1000\n"
ASSIGN = "pack t\nversion 1\nmethod assign\n" + FILT + "new_cost 9.21\nkeep_bonus 2\nstale_ms 1000\n"


def rep(src, uid, t, lat, lon, **kw):
    return dict({"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}, **kw)


def track(key, report, east, north, r=(1.0, 1.0)):
    t = Track(key, key.split("/")[0])
    t.report, t.last_time_ms, t.east, t.north, t.r_meas = report, 0, list(east), list(north), r
    return t


class FloatBoundaries(unittest.TestCase):
    """gate.py `value < limit` (window, mahalanobis), speed `<=`; tracks.py
    restart `d2 < gate`; assign.py bias `d2 < gate` and margin `<= cut`."""

    def test_window_and_mahalanobis_are_strict(self):
        eng = correlate.make_engine(correlate.parse_pack(
            CONFIRM % 2 + "gate window multiplier=2 window_m=1 err_min_m=1 err_max_m=100\n"
            "gate mahalanobis gate=1\n"))
        a = track("a/1", {"ce": 30.0}, [0.0, 0, 1.0, 0, 1], [0.0, 0, 1.0, 0, 1], r=(8.0, 8.0))
        b = track("b/1", {"ce": 40.0}, [101.0, 0, 1.0, 0, 1], [0.0, 0, 1.0, 0, 1])
        trace = []
        self.assertFalse(gate.run_test(eng, "gate", "window", eng.pack.gate[0][1], a, b, trace))
        self.assertEqual((trace[0]["value"], trace[0]["limit"]), (101.0, 101.0))
        b.east[0] = 3.0
        self.assertFalse(gate.run_test(eng, "gate", "mahalanobis", eng.pack.gate[1][1], a, b, trace))
        self.assertEqual(trace[-1]["value"], 1.0)

    def test_speed_limit_is_inclusive(self):
        eng = correlate.make_engine(correlate.parse_pack(CONFIRM % 2 + "gate speed max_pct=25 min_speed_ms=1\n"))
        a = track("a/1", {"speed_ms": 100.0}, [0.0] * 5, [0.0] * 5)
        b = track("b/1", {"speed_ms": 75.0}, [0.0] * 5, [0.0] * 5)
        trace = []
        self.assertTrue(gate.run_test(eng, "gate", "speed", eng.pack.gate[0][1], a, b, trace))
        self.assertEqual(trace[0]["value"], 25.0)

    def test_restart_is_strict(self):
        steps = [rep("a", "1", 0, 0.0, 0.0), rep("a", "1", 1000, 0.0, 0.01)]
        eng = correlate.make_engine(correlate.parse_pack(CONFIRM % 2 + "restart gate=1e300\n"))
        eng.ingest(steps[0])
        d2 = eng.ingest(steps[1])[1][0]["value"]
        eng = correlate.make_engine(correlate.parse_pack(CONFIRM % 2 + "restart gate=%r\n" % d2))
        eng.ingest(steps[0])
        rec = eng.ingest(steps[1])[1][0]
        self.assertEqual((rec["value"], rec["limit"], rec["pass"]), (d2, d2, False))

    def test_bias_gate_is_strict(self):
        vdir = os.path.join(pack_dir("correlate-assign-bias"), "vectors")
        v = load_json(os.path.join(vdir, sorted(os.listdir(vdir))[0]))
        text = read_pack_def("correlate-assign-bias")
        outs, _ = run(correlate.make_engine(correlate.parse_pack(text)), v["steps"])
        first = next(r for _, tr in outs for r in tr if r["stage"] == "bias")
        line = next(l for l in text.splitlines() if l.startswith("bias"))
        at = text.replace(line, " ".join(w if not w.startswith("gate=") else "gate=%r" % first["value"]
                                          for w in line.split()))
        outs, _ = run(correlate.make_engine(correlate.parse_pack(at)), v["steps"])
        rec = next(r for _, tr in outs for r in tr if r["stage"] == "bias")
        self.assertEqual((rec["value"], rec["limit"], rec["pass"]), (first["value"], first["value"], False))

    def test_margin_keeps_a_total_equal_to_the_cut(self):
        """The first tick with two candidate histories of different totals:
        the margin is set so that the cut equals the second total exactly."""
        text = read_pack_def("correlate-assign-full")
        line = next(l for l in text.splitlines() if l.startswith("margin"))
        vdir = os.path.join(pack_dir("correlate-assign-full"), "vectors")
        for f in sorted(os.listdir(vdir)):
            steps = load_json(os.path.join(vdir, f))["steps"]
            outs, _ = run(correlate.make_engine(correlate.parse_pack(text.replace(line, "margin 1e6"))), steps)
            at = totals = None
            for i, (_, tr) in enumerate(outs):
                recs = [r for r in tr if r["stage"] == "history" and r["test"] == "total"]
                groups = []  # one group of candidates per source: the same cut
                for r in recs:
                    if groups and groups[-1][-1]["limit"] == r["limit"]:
                        groups[-1].append(r)
                    else:
                        groups.append([r])
                if any(len(g) >= 2 for g in groups):
                    if len(groups[0]) >= 2:
                        at, totals = i, [r["value"] for r in groups[0]]
                    break
            if at is None or totals[1] <= totals[0]:
                continue
            m = totals[1] - totals[0]
            for _ in range(8):
                if totals[0] + m == totals[1]:
                    break
                m = math.nextafter(m, math.inf if totals[0] + m < totals[1] else -math.inf)
            if totals[0] + m != totals[1] or m <= 0:
                continue
            outs2, _ = run(correlate.make_engine(correlate.parse_pack(text.replace(line, "margin %r" % m))), steps)
            recs = [r for r in outs2[at][1] if r["stage"] == "history" and r["test"] == "total"]
            self.assertEqual([r["value"] for r in recs[:2]], totals[:2])
            self.assertEqual(recs[0]["limit"], recs[1]["limit"])
            self.assertEqual(recs[1]["limit"], totals[1])
            self.assertTrue(recs[1]["pass"])
            return
        self.fail("no tick with two history totals to place the cut on")


class IntegerBoundaries(unittest.TestCase):
    """Staleness `now - last > stale_ms` and `now >= report stale_ms`:
    confirm.py, assign.py, fuse.py (with epoch-sized times)."""

    def test_confirm_stale_is_strict(self):
        eng = correlate.make_engine(correlate.parse_pack(CONFIRM % 2))
        eng.ingest(rep("a", "1", 0, 1.0, 1.0))
        self.assertEqual(eng.tick(1000)[0], [])
        self.assertEqual(eng.tick(1001)[0], [{"ev": "drop", "entity": "a/1"}])

    def test_assign_stale(self):
        eng = correlate.make_engine(correlate.parse_pack(ASSIGN))
        eng.ingest(rep("a", "1", 0, 1.0, 1.0))
        eng.ingest(rep("b", "1", 0, 1.0, 1.5, stale_ms=500))
        eng.tick(0)
        events, _ = eng.tick(500)
        self.assertIn({"ev": "drop", "entity": "b/1"}, events)
        self.assertNotIn({"ev": "drop", "entity": "a/1"}, events)
        events, _ = eng.tick(1000)
        self.assertNotIn({"ev": "drop", "entity": "a/1"}, events)
        self.assertIn({"ev": "drop", "entity": "a/1"}, eng.tick(1001)[0])

    def test_fuse_stale_with_epoch_times(self):
        eng = fuse.make_engine(fuse.parse_pack("pack t\nversion 1\n" + FILT + "kinematics best\nstale_ms 5000\n"))
        t0 = 1_700_000_000_000
        eng.ingest(rep("a", "1", t0, 1.0, 1.0))
        self.assertEqual([e["ev"] for e in eng.tick(t0 + 5000)[0]], ["fused"])
        self.assertEqual(eng.tick(t0 + 5001)[0][0]["ev"], "drop")


class Confirm(unittest.TestCase):
    def test_rank_tie_goes_to_key_order(self):
        """confirm.py `d2 < best_d2`: two candidates at exactly equal d2."""
        text = CONFIRM % 2 + "gate distance max_m=150\n"
        eng = correlate.make_engine(correlate.parse_pack(text))
        eng.ingest(rep("a", "1", 0, 0.0, 0.0))     # the frame's reference: east 0
        eng.ingest(rep("b", "1", 0, 0.0, -0.001))
        eng.ingest(rep("c", "1", 0, 0.0, 0.001))
        events, trace = eng.ingest(rep("a", "1", 0, 0.0, 0.0))
        ranks = [r["value"] for r in trace if r["stage"] == "rank"]
        self.assertEqual(len(ranks), 2)
        self.assertEqual(ranks[0], ranks[1])
        self.assertEqual(events, [{"ev": "correlate", "group": "g1", "members": ["a/1", "b/1"]}])

    def test_priority_default_is_100(self):
        """confirm.py: an unlisted source has priority 100, ties to key order."""
        eng = correlate.make_engine(correlate.parse_pack(CONFIRM % 1 + "priority b 100\n"))
        eng.ingest(rep("a", "1", 0, 1.0, 1.0))
        eng.ingest(rep("b", "1", 0, 1.0, 1.0))
        events, _ = eng.tick(0)
        self.assertEqual(events[0]["primary"], "a/1")


class TwoModel(unittest.TestCase):
    def test_all_four_likelihood_terms(self):
        """estimate.py: every term y*y/s + ln(s), east and north, position and velocity."""
        e, n = estimate.first_axes(0.0, 0.0, 100.0, 100.0, (1.0, 2.0), {"vel_sigma_ms": 5.0, "unknown_vel_ms": 9.0})
        man = {"accel_var": 10.0, "p_enter": 0.1, "p_leave": 0.2}
        q = (1.0, 10.0)
        models, mode = [[e, n], [list(e), list(n)]], [0.5, 0.5]
        _, _, _, _, lam = estimate.two_model_update(models, mode, man, q, 0.0, 3.0, 4.0, (100.0, 100.0),
                                                    (5.0, 7.0), 25.0)
        terms = []
        ax_e, y1, s1 = estimate.pos_step(e, 3.0, 100.0)
        ax_n, y2, s2 = estimate.pos_step(n, 4.0, 100.0)
        _, y3, s3 = estimate.vel_step(ax_e, 5.0, 25.0)
        _, y4, s4 = estimate.vel_step(ax_n, 7.0, 25.0)
        for y, s in ((y1, s1), (y2, s2), (y3, s3), (y4, s4)):
            terms.append(y * y / s + math.log(s))
        g = 0.0
        for t in terms:
            g += t
        self.assertEqual(lam[0], -0.5 * g)  # dt 0: no mixing change, quiet model as given

    def test_collapsed_mode_at_the_same_time(self):
        """estimate.py `c[j] > 0` (twice): a model whose probability is 0 is
        left out of the maximum and of the weights."""
        e, n = estimate.first_axes(0.0, 0.0, 1e-6, 1e-6, None, {"vel_sigma_ms": 5.0, "unknown_vel_ms": 1e-3})
        wide = ([0.0, 0.0, 1e6, 0.0, 1.0], [0.0, 0.0, 1e6, 0.0, 1.0])
        man = {"accel_var": 10.0, "p_enter": 0.1, "p_leave": 0.2}
        models = [[e, n], [list(wide[0]), list(wide[1])]]
        _, mu, _, _, lam = estimate.two_model_update(models, [1.0, 0.0], man, (0.0, 10.0), 0.0, 100.0, 0.0,
                                                     (1e-6, 1e-6), None, 25.0)
        self.assertGreater(lam[1] - lam[0], 745)
        self.assertEqual(mu, [1.0, 0.0])


class MoreQuality(unittest.TestCase):
    def test_median_of_an_odd_count(self):
        self.assertEqual(Q._median([1, 2, 4, 8, 16]), 4)

    def test_filter_parameter_below_one(self):
        Q.parse_pack(Quality.BASE.replace("vel_sigma_ms=5", "vel_sigma_ms=0.5"))


class MoreTimeVariance(unittest.TestCase):
    def test_first_report_without_velocity(self):
        """tracks.py: no velocity, no prediction: the timing variance is 0."""
        eng = correlate.make_engine(correlate.parse_pack(ASSIGN + "time_default a error_ms=100\n"))
        _, trace = eng.ingest(rep("a", "1", 0, 1.0, 1.0))
        self.assertEqual((trace[0]["var_east"], trace[0]["var_north"]), (0.0, 0.0))

    def test_both_measurement_variances(self):
        eng = correlate.make_engine(correlate.parse_pack(ASSIGN + "time_default a error_ms=100\n"))
        _, trace = eng.ingest(rep("a", "1", 0, 1.0, 1.0, course=30.0, speed_ms=100.0))
        self.assertEqual(eng.entities["a/1"].r_meas,
                         (2500.0 + trace[0]["var_east"], 2500.0 + trace[0]["var_north"]))


class Course(unittest.TestCase):
    def test_a_course_that_rounds_to_360_is_0(self):
        """model.py course_deg: [0, 360), a tiny negative course adds up to 360.0."""
        self.assertEqual(model.course_deg(-1e-16, 1.0), 0.0)
        self.assertEqual(model.course_deg(-1.0, 1.0), 315.0)


class TimeVariance(unittest.TestCase):
    def test_both_axes(self):
        """tracks.py `(ve * ts) ** 2`, `(vn * ts) ** 2`; snapshot.py and tracks.py `te > 0` with te below 1."""
        eng = correlate.make_engine(correlate.parse_pack(ASSIGN + "time_default a error_ms=0.5\n"))
        _, trace = eng.ingest(rep("a", "1", 0, 1.0, 1.0, course=45.0, speed_ms=100.0))
        ve, vn = model.velocity(45.0, 100.0)
        self.assertEqual(trace[0]["var_east"], (ve * 0.0005) ** 2)
        self.assertEqual(trace[0]["var_north"], (vn * 0.0005) ** 2)
        snap = eng.snapshot()["entities"]["a/1"]
        self.assertEqual(snap["time"], {"var_east": trace[0]["var_east"], "var_north": trace[0]["var_north"]})


class CorrelatePack(unittest.TestCase):
    def ok(self, extra, base=None):
        return correlate.parse_pack((base or ASSIGN) + extra)

    def bad(self, extra, base=None):
        with self.assertRaises(PackError):
            correlate.parse_pack((base or ASSIGN) + extra)

    def test_values_at_their_bounds(self):
        self.assertEqual(self.ok("").name, "t")
        self.assertEqual(self.ok("").version, "1")
        self.ok("", ASSIGN.replace("accel_var=1", "accel_var=0.5"))
        self.ok("", ASSIGN.replace("accel_var=1", "accel_var=0"))
        self.bad("maneuver accel_var=5 p_enter=0 p_leave=0.2\n")
        self.bad("maneuver accel_var=5 p_enter=0.2 p_leave=0\n")
        self.ok("restart gate=0.5\n")
        self.ok("bias sigma_m=1 floor_m=0.5 gate=0.5\n")
        self.bad("bias sigma_m=1 floor_m=0 gate=1\n")
        self.ok("", ASSIGN.replace("keep_bonus 2", "keep_bonus 0"))
        self.ok("", ASSIGN.replace("keep_bonus 2", "keep_bonus 0.5").replace("new_cost 9.21", "new_cost 0.5"))
        self.bad("time_default\n")
        self.ok("", ASSIGN.replace("vel_sigma_ms=5", "vel_sigma_ms=0.5"))
        self.bad("bias sigma_m=1 floor_m=0.5 gate=0\n")


class Filter(unittest.TestCase):
    PACK = "pack t\nversion 1\ndefault keep\nforget_ms 1000\n"

    def eng(self, rules):
        return F.make_engine(F.parse_pack(self.PACK + rules))

    def test_pack_bounds(self):
        F.parse_pack(self.PACK.replace("forget_ms 1000", "forget_ms 9223372036854775807"))
        F.parse_pack(self.PACK.replace("forget_ms 1000", "forget_ms 1"))
        F.parse_pack(self.PACK + "rule a keep\nwhen circle lat=90 lon=180 radius_m=1\n")
        F.parse_pack(self.PACK + "rule a keep\nwhen circle lat=-90 lon=-180 radius_m=1\n")
        for bad in ("lat=-91 lon=0", "lat=0 lon=-181", "lat=91 lon=0", "lat=0 lon=181"):
            with self.assertRaises(PackError):
                F.parse_pack(self.PACK + "rule a keep\nwhen circle %s radius_m=1\n" % bad)
        p = F.parse_pack(self.PACK + "rule a keep\nwhen key name=x eq=a=b\n")
        self.assertEqual(p.rules[0].conditions[0].p["eq"], "a=b")

    def test_affiliation_of_two_elements(self):
        self.assertEqual(F.affiliation({"type": "a-h"}), "h")

    def test_radius_is_inclusive(self):
        eng = self.eng("rule here drop\nwhen circle lat=10 lon=20 radius_m=0\n"
                       "rule near drop\nwhen near reference=o/1 radius_m=0 max_age_ms=0\n")
        self.assertEqual(eng.ingest(rep("s", "1", 0, 10.0, 20.0))[0][0]["rule"], "here")
        t0 = 1_700_000_000_000
        eng.ingest(rep("o", "1", t0, 30.0, 40.0))
        self.assertEqual(eng.ingest(rep("s", "1", t0, 30.0, 40.0))[0][0]["rule"], "near")

    def test_near_a_moving_reference_at_epoch_times(self):
        """filter.py predict: dt, dn, de, and the latitude step."""
        eng = self.eng("rule near drop\nwhen near reference=o/1 radius_m=5 max_age_ms=10000\n")
        t0 = 1_700_000_000_000
        eng.ingest(rep("o", "1", t0, 10.0, 20.0, course=30.0, speed_ms=100.0))
        lat, lon = F.predict({"time_ms": t0, "lat": 10.0, "lon": 20.0, "course": 30.0, "speed_ms": 100.0},
                             t0 + 2000)
        dn = 100.0 * math.cos(F.rad(30.0)) * 2.0
        de = 100.0 * math.sin(F.rad(30.0)) * 2.0
        self.assertEqual(lat, 10.0 + F.deg(dn / F.R))
        self.assertEqual(lon, F.wrap(20.0 + F.deg(de / (F.R * math.cos(F.rad(10.0))))))
        events, trace = eng.ingest(rep("s", "1", t0 + 2000, lat, lon))
        self.assertEqual(events[0]["rule"], "near")
        self.assertLess(trace[0]["value"], 1e-6)
        events, _ = eng.ingest(rep("s", "1", t0 + 2001, 10.0, 20.0))
        self.assertEqual(events[0]["rule"], "default")

    def test_polygon_edges_and_vertices(self):
        tri = [(0.0, 0.0), (10.0, 10.0), (0.0, 10.0)]   # (lat, lon): a diagonal edge
        self.assertEqual(F.polygon(tri, 5.0, 5.0), "boundary")
        self.assertEqual(F.polygon(tri, 2.0, 8.0), "inside")
        self.assertEqual(F.polygon(tri, 8.0, 2.0), "outside")
        self.assertEqual(F.polygon(tri, 4.0, 5.0), "inside")
        self.assertEqual(F.polygon(tri, 6.0, 5.0), "outside")
        sq = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]
        for v in sq:
            self.assertEqual(F.polygon(sq, v[0], v[1]), "boundary")
        off = [(2.0, 2.0), (12.0, 12.0), (2.0, 12.0)]   # the same, no vertex at 0
        self.assertEqual(F.polygon(off, 7.0, 7.0), "boundary")
        self.assertEqual(F.polygon(off, 6.0, 7.0), "inside")
        self.assertEqual(F.polygon(off, 8.0, 7.0), "outside")
        diamond = [(0.0, 5.0), (5.0, 10.0), (10.0, 5.0), (5.0, 0.0)]
        self.assertEqual(F.polygon(diamond, 5.0, 2.0), "inside")      # at a vertex's latitude
        self.assertEqual(F.polygon(diamond, 5.0, 12.0), "outside")
        self.assertEqual(F.polygon(diamond, 5.0, -2.0), "outside")
        self.assertEqual(F.polygon(diamond, 0.0, 6.0), "outside")


class Fuse(unittest.TestCase):
    def test_boolean_majority(self):
        self.assertTrue(fuse._same(True, True))
        self.assertFalse(fuse._same(True, False))

    def test_ci_weight_clamps(self):
        """fuse.py ci_weight: a maximum below 0 is 0, above 1 is 1."""
        def ax(pe, pn):
            return [[0.0, 0.0, pe, 0.0, 1.0], [0.0, 0.0, pn, 0.0, 1.0]]

        def raw(x, y):
            de, dn = 1.0 / x[0][2] - 1.0 / y[0][2], 1.0 / x[1][2] - 1.0 / y[1][2]
            ae, an = 1.0 / y[0][2], 1.0 / y[1][2]
            c2, c1 = de * dn, ae * dn + an * de
            self.assertLess(c2, 0)
            return -c1 / (2.0 * c2)
        below, above = (ax(3.0, 2.0), ax(4.0, 1.0)), (ax(4.0, 3.0), ax(3.0, 10.0))
        self.assertLess(raw(*below), 0.0)
        self.assertGreater(raw(*above), 1.0)
        self.assertEqual(fuse.ci_weight(*below), 0.0)
        self.assertEqual(fuse.ci_weight(*above), 1.0)

    def test_ci_fold_velocity(self):
        x = [[0.0, 1.0, 1.0, 0.0, 2.0], [0.0, 3.0, 1.0, 0.0, 4.0]]
        y = [[1.0, 5.0, 2.0, 0.0, 6.0], [1.0, 7.0, 2.0, 0.0, 8.0]]
        out = fuse.ci_fold(x, y, 0.25)
        for X, Y, o in zip(x, y, out):
            c, d = 0.25 / X[4], 0.75 / Y[4]
            vv = 1.0 / (c + d)
            self.assertEqual(o[4], vv)
            self.assertEqual(o[1], vv * (c * X[1] + d * Y[1]))

    def test_max_ties_to_key_order(self):
        eng = fuse.make_engine(fuse.parse_pack("pack t\nversion 1\n" + FILT +
                                               "kinematics best\nstale_ms 5000\nattribute x rule=max\n"))
        eng.ingest(rep("a", "1", 0, 1.0, 1.0, x=5, **{"fuse.group": "g"}))
        eng.ingest(rep("b", "1", 0, 1.0, 1.0, x=5.0, **{"fuse.group": "g"}))
        self.assertEqual(eng.tick(0)[0][0]["attributes"]["x"], {"value": 5, "from": "a/1"})

    def test_pack(self):
        base = "pack t\nversion 1\n" + FILT + "kinematics best\nstale_ms 5000\n"
        fuse.parse_pack(base.replace("vel_sigma_ms=5", "vel_sigma_ms=0.5"))
        p = fuse.parse_pack(base.replace("accel_var=1", "accel_var=0.5"))
        self.assertEqual((p.name, p.version), ("t", "1"))
        with self.assertRaises(PackError):
            fuse.parse_pack(base + "attribute x rule=max=1\n")


class Quality(unittest.TestCase):
    BASE = "pack t\nversion 1\n" + FILT + "window window_ms=1 min_samples=1 forget_ms=1\n"

    def test_pack_bounds(self):
        p = Q.parse_pack(self.BASE.rstrip("\n"))  # no newline at the end: the last line counts
        self.assertEqual((p.name, p.version, p.window_ms, p.min_samples, p.forget_ms), ("t", "1", 1, 1, 1))
        Q.parse_pack(self.BASE + "rule r scope=entity measure=age op=< limit=5 for=1 clear=5 action=alert\n")
        for bad in ("rule\n", "time_default\n"):
            with self.assertRaises(PackError):
                Q.parse_pack(self.BASE + bad)
        with self.assertRaises(ValueError):
            Q.extend_measures(Q.MEASURES, "entities", Q.Measure("sum", lambda w: 0))

    def test_time_error_zero_and_small_ce(self):
        eng = Q.make_engine(Q.parse_pack(self.BASE.replace("window_ms=1 ", "window_ms=1000 ") +
                                         "time_default s error_ms=5\n"
                                         "rule d scope=entity measure=reports op=>= limit=1 for=1 clear=0 "
                                         "action=downgrade factor=2\n"))
        _, trace = eng.ingest(rep("s", "1", 0, 1.0, 1.0, time_error_ms=0, ce=0.5))
        te = [r for r in trace if r["sample"] == "time_error"][0]
        self.assertEqual(te["value"], 0.0)
        eng.tick(0)
        out = eng.ingest(rep("s", "1", 1, 1.0, 1.0, ce=0.5))[0][-1]
        self.assertEqual(out["report"]["ce"], 1.0)


class Runner(unittest.TestCase):
    def call(self, argv):
        import contextlib
        import io
        import json
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = main(argv, FUNCTIONS)
        return code, (json.loads(out.getvalue()) if out.getvalue() else None)

    def test_flags_and_counters(self):
        import json
        import tempfile
        f = os.path.join(pack_dir("filter-thin"), "vectors", sorted(os.listdir(pack_dir("filter-thin") + "/vectors"))[0])
        v = load_json(f)
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, "e")
            code, c = self.call(["--trace", "--function", "filter", "--pack", pack_dir("filter-thin"),
                                 "--steps", f, "--events", ev])
            self.assertEqual(code, 0)
            self.assertIn("trace", json.loads(open(ev, encoding="utf-8").readline()))
            self.assertEqual(c["ingest"], sum(1 for s in v["steps"] if "ingest" in s))
            self.assertEqual(c["tick"], sum(1 for s in v["steps"] if "tick" in s))
            for k in ("parse_ns", "load_ns", "run_ns"):
                self.assertTrue(0 <= c[k] < 60 * 10 ** 9, k)
            code, _ = self.call(["--function", "filter", "--pack", pack_dir("filter-thin"), "--steps", f,
                                 "--events", ev])
            self.assertNotIn("trace", json.loads(open(ev, encoding="utf-8").readline()))
            self.assertEqual(self.call(["--function", "filter", "--pack", pack_dir("filter-thin"), "--steps", f,
                                        "--events"])[0], 2)


if __name__ == "__main__":
    unittest.main()
