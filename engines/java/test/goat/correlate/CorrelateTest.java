package goat.correlate;

import goat.io.LoadError;
import goat.testkit.Check;
import goat.trace.Result;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Unit tests of the correlate module: the pack, the registry, the tests, the report path. */
public final class CorrelateTest {
    private CorrelateTest() {}

    static final String CONFIRM = "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
            + "gate distance max_m=1000\nconfirm_count 1\nhold distance max_m=2000\nhold_failures 2\nstale_ms 10000\n";
    static final String ASSIGN = "pack p\nversion 1\nmethod assign\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
            + "gate mahalanobis gate=18.42\nnew_cost 9.21\nkeep_bonus 2\nstale_ms 10000\n";

    public static void testPacksParse() throws LoadError {
        CorrelatePack c = CorrelatePack.parse(CONFIRM);
        Check.eq("confirm", c.method, "default method");
        Check.eq(1, c.gate.size(), "gate");
        Check.same(1000, c.gate.get(0).p("max_m"), "parameter");
        CorrelatePack a = CorrelatePack.parse(ASSIGN);
        Check.eq("assign", a.method, "method assign");
        Check.same(9.21, a.newCost, "new_cost");
        Check.eq(1L, a.window, "window default 1");
        Check.isTrue(a.filter != null && !a.filter.maneuver, "filter parameters");
    }

    public static void testMethodDirectivesRefused() {
        LoadError e = Check.throwsA(LoadError.class, () -> CorrelatePack.parse(CONFIRM + "new_cost 3\n"), "assign directive with confirm");
        Check.eq("pack.def line 9: new_cost is not a directive of method confirm", e.getMessage(), "message");
        LoadError f = Check.throwsA(LoadError.class, () -> CorrelatePack.parse(ASSIGN + "hold_failures 3\n"), "confirm directive with assign");
        Check.isTrue(f.getMessage().endsWith("hold_failures is not a directive of method assign"), f.getMessage());
        LoadError g = Check.throwsA(LoadError.class, () -> CorrelatePack.parse(CONFIRM.replace("pack p\n", "pack p\nmethod sort\n")), "unknown method");
        Check.isTrue(g.getMessage().endsWith("method is confirm or assign"), g.getMessage());
    }

    public static void testPackErrors() {
        for (String bad : List.of(
                CONFIRM.replace("confirm_count 1\n", ""),
                CONFIRM + "gate distance\n",
                CONFIRM + "gate distance max_m=1 max_m=2\n",
                CONFIRM + "gate nearest gate=1\n",
                CONFIRM + "gate same key=\n",
                CONFIRM + "stale_ms 5\n",
                CONFIRM + "bogus 1\n",
                CONFIRM.replace("accel_var=1", "accel_var=-1"),
                CONFIRM.replace("default_ce_m=50", "default_ce_m=0"),
                CONFIRM.replace("max_m=1000", "max_m=1e"),
                CONFIRM + "maneuver accel_var=0.5 p_enter=0.1 p_leave=0.2\n",
                CONFIRM + "maneuver accel_var=5 p_enter=0.5 p_leave=0.5\n",
                CONFIRM + "restart gate=0\n",
                CONFIRM + "time_default s error_ms=-1\n",
                CONFIRM + "time_default s state=late\n",
                CONFIRM + "time_default s\n",
                CONFIRM + "time_default s error_ms=1\ntime_default s state=drifting\n",
                CONFIRM + "priority s\n",
                CONFIRM + "output first\n",
                CONFIRM + "same_source maybe\n",
                ASSIGN + "hypotheses 2\n",
                ASSIGN + "window 2\nmargin 1\n",
                ASSIGN + "time_offset sigma_ms=10\n",
                ASSIGN + "bias sigma_m=10 floor_m=20 gate=5\n",
                ASSIGN + "window 0\n",
                ASSIGN + "keep_bonus -1\n",
                ASSIGN.replace("method assign\n", "")))
            Check.throwsA(LoadError.class, () -> CorrelatePack.parse(bad), "load error: " + bad);
    }

    public static void testValues() throws LoadError {
        Check.same(0.5, CorrelatePack.dec(".5", 1), "leading point");
        Check.same(1500, CorrelatePack.dec("+1.5e3", 1), "sign and exponent");
        Check.eq(-3L, CorrelatePack.integer("-3", 1), "integer");
        Check.eq(3L, CorrelatePack.integer("+3", 1), "plus sign");
        Check.throwsA(LoadError.class, () -> CorrelatePack.integer("99999999999999999999", 1), "out of range");
        Check.throwsA(LoadError.class, () -> CorrelatePack.dec("1.2.3", 1), "two points");
    }

    public static void testStandardRegistry() {
        for (String t : List.of("distance", "mahalanobis", "course", "speed", "altitude", "same", "state"))
            Check.isTrue(Registry.STANDARD.test(t) != null, "test " + t);
        Check.isTrue(Registry.STANDARD.test("window") == null, "window is retired (correlate.md 1.0)");
        Check.eq("confirm", Registry.STANDARD.ownerOf("sprt"), "sprt is confirm's");
        Check.eq(null, Registry.STANDARD.ownerOf("stale_rate"), "stale_rate is every method's");
        Check.eq(List.of("confirm", "assign"), List.copyOf(Registry.STANDARD.methods().keySet()), "methods");
        Check.eq("assign", Registry.STANDARD.ownerOf("new_cost"), "new_cost is assign's");
        Check.eq("confirm", Registry.STANDARD.ownerOf("hold"), "hold is confirm's");
        Check.eq(null, Registry.STANDARD.ownerOf("gate"), "gate is every method's");
        Registry more = Registry.STANDARD.withTest(new TestKind("x", List.of(), (t, s, a, b, pb) -> null));
        Check.isTrue(more.test("x") != null && Registry.STANDARD.test("x") == null, "with returns a new registry");
    }

    static Map<String, Object> report(String src, String uid, long t, double lat, double lon) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("track.source_id", src);
        r.put("uid", uid);
        r.put("time_ms", t);
        r.put("lat", lat);
        r.put("lon", lon);
        return r;
    }

    public static void testReportPath() throws LoadError {
        Correlator c = Correlator.fromText(CONFIRM);
        Check.eq("new", c.ingest(report("a", "1", 1000, 50, 10)).events.get(0).get("ev"), "first report");
        Result old = c.ingest(report("a", "1", 999, 50, 10));
        Check.eq("out-of-order", old.events.get(0).get("reason"), "older than the last");
        Result pair = c.ingest(report("b", "1", 1000, 50.0001, 10));
        Check.eq("correlate", pair.events.get(1).get("ev"), "within 1000 m on one report: a group");
        Check.eq(List.of(50.0, 10.0), c.snapshot().get("ref"), "the first report is the reference");
    }

    public static void testTimeErrorAddsTimingVariance() throws LoadError {
        Correlator c = Correlator.fromText(ASSIGN);
        Map<String, Object> r = report("a", "1", 1000, 50, 10);
        r.put("course", 90L);
        r.put("speed_ms", 100L);
        r.put("time_error_ms", 200L);
        Result res = c.ingest(r);
        Map<String, Object> rec = res.trace.get(0);
        Check.eq("time", rec.get("test"), "time record");
        Check.near(400, (Double) rec.get("var_east"), 1e-9, "(100 m/s * 0.2 s)^2 east");
        Check.near(0, (Double) rec.get("var_north"), 1e-9, "none north");
        Entity e = c.entities().get("a/1");
        Check.near(2500 + 400, e.r[0], 1e-9, "r east = ce^2 + timing variance");
    }

    public static void testStaleness() throws LoadError {
        Correlator c = Correlator.fromText(CONFIRM);
        Map<String, Object> r = report("a", "1", 1000, 50, 10);
        r.put("stale_ms", 5000L);
        c.ingest(r);
        Entity e = c.entities().get("a/1");
        Check.isTrue(!c.isStale(e, 4999), "before stale_ms");
        Check.isTrue(c.isStale(e, 5000), "at the report's stale_ms");
        Check.eq("drop", c.tick(5000).events.get(0).get("ev"), "dropped on the tick");
    }

    public static void testMahalanobis() throws LoadError {
        Correlator c = Correlator.fromText(ASSIGN);
        c.ingest(report("a", "1", 1000, 50, 10));
        c.ingest(report("b", "1", 1000, 50.001, 10));
        Entity a = c.entities().get("a/1"), b = c.entities().get("b/1");
        Predicted pb = Predicted.forComparison(b, a.lastTime);
        double d = goat.model.Frame.R * goat.model.Frame.rad(0.001);
        Check.near(d * d / (2500 + 2500), Tests.mahalanobis(a, pb), 1e-9, "d^2 / (pp_b + r_a)");
    }

    /** correlate.md 1.0: stale time from the lower median, the state test's table, the sprt bounds and line. */
    public static void testStaleRateStateSprt() throws LoadError {
        Check.same(12000, Correlator.staleTime(3, 1000, 60000, List.of(4000L, 5000L, 4000L, 9000L)), "k * lower median");
        Check.same(1000, Correlator.staleTime(0.1, 1000, 60000, List.of(4000L)), "raised to the floor");
        Check.same(60000, Correlator.staleTime(100, 1000, 60000, List.of(4000L)), "lowered to the ceiling");
        Check.same(13.2767, Tests.chiSquare(0.990, 4), "0.990 is 0.99");
        Check.same(20.5150, Tests.chiSquare(0.999, 5), "5 dof");
        Check.isTrue(Double.isNaN(Tests.chiSquare(0.9, 4)), "not in the table");
        String base = CONFIRM.replace("confirm_count 1\n", "").replace("hold distance max_m=2000\n", "")
                .replace("hold_failures 2\n", "");
        CorrelatePack p = CorrelatePack.parse(base + "sprt false=0.01 missed=0.1 pos_m=100 vel_ms=10 hae_sigma_m=20\n");
        Check.near(Math.log(0.9 / 0.01), Sprt.up(p), 1e-12, "up");
        Check.near(Math.log(0.1 / 0.99), Sprt.lo(p), 1e-12, "lo");
        Check.same(Sprt.up(p), Sprt.update(4, 100, Sprt.lo(p), Sprt.up(p)), "clamped to up");
        Check.eq("fused", p.output, "fused is the default output");
        Check.throwsA(LoadError.class, () -> CorrelatePack.parse(CONFIRM + "sprt false=0.01 missed=0.1 pos_m=100 vel_ms=10 hae_sigma_m=20\n"),
                "confirm_count with sprt");
        Check.throwsA(LoadError.class, () -> CorrelatePack.parse(base + "sprt false=0.5 missed=0.1 pos_m=100 vel_ms=10 hae_sigma_m=20\n"),
                "false below 0.5");
        Check.throwsA(LoadError.class, () -> CorrelatePack.parse(CONFIRM + "stale_rate factor=3 floor_ms=0 ceiling_ms=10 samples=4\n"),
                "stale_ms and stale_rate");
        Check.throwsA(LoadError.class, () -> CorrelatePack.parse(CONFIRM + "gate state probability=0.9 hae_sigma_m=20\n"),
                "probability not in the table");
    }
}
