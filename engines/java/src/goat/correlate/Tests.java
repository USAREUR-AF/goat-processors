package goat.correlate;

import goat.model.Axis;
import goat.trace.Result;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** correlate.md, Tests: the registered test kinds, how a stage runs them, and their trace records. */
public final class Tests {
    private Tests() {}

    /**
     * Runs tests in order, stopping at the first that fails; true when all ran and passed.
     * B's timing variance first (Track estimate, Measurement variance), then, with a move, B's
     * prediction moved into A's frame (correlate-assign.md, Sensor bias), before the test formula.
     */
    public static boolean run(List<CorrelatePack.Test> tests, String stage, Entity a, Entity b, FrameMove move,
                              Result res) {
        Predicted pb = Predicted.forComparison(b, a.lastTime);
        if (move != null) {
            Axis[] moved = move.moveInto(a.source, b.source, pb.axes());
            pb = new Predicted(moved[0], moved[1]);
        }
        for (CorrelatePack.Test t : tests) {
            Map<String, Object> r = t.kind.formula.apply(t, stage, a, b, pb);
            res.trace.add(r);
            if (!(Boolean) r.get("pass")) return false;
        }
        return true;
    }

    /**
     * correlate.md, Tests table: each test's parameters and formula, in table order. A new test is
     * one more entry here (or {@link Registry#withTest} from outside).
     */
    static final List<TestKind> STANDARD = List.of(
            new TestKind("distance", List.of("max_m"), (t, stage, a, b, pb) -> {
                double d = distance(a, pb);
                return rec(stage, a, b, t.name, d, t.p("max_m"), d < t.p("max_m"), false);
            }),
            new TestKind("window", List.of("multiplier", "window_m", "err_min_m", "err_max_m"), (t, stage, a, b, pb) -> {
                double d = distance(a, pb);
                double ea = clamp(a.ce, t.p("err_min_m"), t.p("err_max_m"));
                double eb = clamp(b.ce, t.p("err_min_m"), t.p("err_max_m"));
                double limit = t.p("multiplier") * Math.sqrt(ea * ea + eb * eb) + t.p("window_m");
                return rec(stage, a, b, t.name, d, limit, d < limit, false);
            }),
            new TestKind("mahalanobis", List.of("gate"), (t, stage, a, b, pb) -> {
                double d2 = mahalanobis(a, pb);
                return rec(stage, a, b, t.name, d2, t.p("gate"), d2 < t.p("gate"), false);
            }),
            new TestKind("course", List.of("max_deg", "min_speed_ms"), (t, stage, a, b, pb) -> {
                Double ca = a.num("course"), cb = b.num("course");
                if (ca == null || cb == null || slow(a, b, t.p("min_speed_ms")))
                    return rec(stage, a, b, t.name, null, null, true, true);
                double diff = Math.abs(ca - cb);
                double v = Math.min(diff, 360 - diff);
                return rec(stage, a, b, t.name, v, t.p("max_deg"), v <= t.p("max_deg"), false);
            }),
            new TestKind("speed", List.of("max_pct", "min_speed_ms"), (t, stage, a, b, pb) -> {
                if (slow(a, b, t.p("min_speed_ms")))
                    return rec(stage, a, b, t.name, null, null, true, true);
                double sa = a.num("speed_ms"), sb = b.num("speed_ms");
                double fast = Math.max(sa, sb);
                double v = fast == 0 ? 0 : Math.abs(1 - Math.min(sa, sb) / fast) * 100;
                return rec(stage, a, b, t.name, v, t.p("max_pct"), v <= t.p("max_pct"), false);
            }),
            new TestKind("altitude", List.of("max_m"), (t, stage, a, b, pb) -> {
                Double ha = a.num("hae"), hb = b.num("hae");
                if (ha == null || hb == null) return rec(stage, a, b, t.name, null, null, true, true);
                double v = Math.abs(ha - hb);
                return rec(stage, a, b, t.name, v, t.p("max_m"), v <= t.p("max_m"), false);
            }),
            new TestKind("same", List.of("key"), Set.of("key"), (t, stage, a, b, pb) -> {
                Object va = sameValue(a, t.key), vb = sameValue(b, t.key);
                return rec(stage, a, b, t.name, va, vb, sameEqual(va, vb), false);
            }));

    /** Speed missing on either entity, or below min_speed_ms on either. */
    private static boolean slow(Entity a, Entity b, double min) {
        Double sa = a.num("speed_ms"), sb = b.num("speed_ms");
        return sa == null || sb == null || sa < min || sb < min;
    }

    private static double clamp(double x, double lo, double hi) {
        return Math.max(lo, Math.min(hi, x));
    }

    private static double distance(Entity a, Predicted pb) {
        double de = a.filter.east().p - pb.east.p, dn = a.filter.north().p - pb.north.p;
        return Math.sqrt(de * de + dn * dn);
    }

    /**
     * d² = sum over east, north of (pa - pb)² / (pp_b + r_a), r_a A's measurement variance on
     * that axis (ce_a² when A's last report has time error 0); pb already holds B's timing variance.
     */
    static double mahalanobis(Entity a, Predicted pb) {
        double de = a.filter.east().p - pb.east.p, dn = a.filter.north().p - pb.north.p;
        return de * de / (pb.east.pp + a.r[0]) + dn * dn / (pb.north.pp + a.r[1]);
    }

    /** `@env` is the third `-`-separated element of `type`; absent with fewer than three. */
    private static Object sameValue(Entity e, String key) {
        if (!key.equals("@env")) return e.last.get(key);
        Object type = e.last.get("type");
        if (!(type instanceof String)) return null;
        String[] parts = ((String) type).split("-", -1);
        return parts.length >= 3 ? parts[2] : null;
    }

    private static boolean sameEqual(Object x, Object y) {
        if (x == null || y == null) return x == null && y == null;
        if (x instanceof Number && y instanceof Number)
            return ((Number) x).doubleValue() == ((Number) y).doubleValue();
        return x.equals(y);
    }

    /** correlate.md, Trace, one record; {@code skipped} only when true. */
    static Map<String, Object> rec(String stage, Entity a, Entity b, String test,
                                   Object value, Object limit, boolean pass, boolean skipped) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", stage);
        m.put("a", a.key);
        m.put("b", b.key);
        m.put("test", test);
        m.put("value", value);
        m.put("limit", limit);
        m.put("pass", pass);
        if (skipped) m.put("skipped", true);
        return m;
    }
}
