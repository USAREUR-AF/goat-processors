package goat.model;

import goat.testkit.Check;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Unit tests of the model module: Axis, TrackEstimate, Frame, Report, KeyOrder, InverseVariance. */
public final class ModelTest {
    private ModelTest() {}

    static Axis axis() {
        return new Axis(1, 2, 3, 0.5, 4);
    }

    public static void testAxisPredict() {
        Axis a = axis().predict(2, 0.5);
        Check.same(5, a.p, "p");
        Check.same(2, a.v, "v");
        Check.same(23, a.pp, "pp");
        Check.same(10.5, a.pv, "pv");
        Check.same(6, a.vv, "vv");
    }

    public static void testAxisIsAValue() {
        Axis a = axis();
        a.predict(2, 0.5);
        a.updatePosition(3, 1);
        a.updateVelocity(4, 4);
        a.plusPp(9);
        Check.eq(List.of(1.0, 2.0, 3.0, 0.5, 4.0), a.toList(), "unchanged");
    }

    public static void testAxisUpdatePosition() {
        Axis a = axis().updatePosition(3, 1);
        Check.eq(List.of(2.5, 2.25, 0.75, 0.125, 3.9375), a.toList(), "updated");
        Check.same(1 + Math.log(4), axis().positionTerm(3, 1), "term");
    }

    public static void testAxisUpdateVelocity() {
        Axis a = axis().updateVelocity(4, 4);
        Check.eq(List.of(1.125, 3.0, 2.96875, 0.25, 2.0), a.toList(), "updated");
        Check.same(4.0 / 8 + Math.log(8), axis().velocityTerm(4, 4), "term");
    }

    public static void testAxisWith() {
        Check.eq(List.of(1.0, 2.0, 5.0, 0.5, 4.0), axis().plusPp(2).toList(), "plusPp");
        Check.eq(List.of(7.0, 2.0, 8.0, 0.5, 4.0), axis().withP(7, 8).toList(), "withP");
    }

    static FilterParams params(boolean maneuver) {
        return new FilterParams(1, 50, 5, 100, maneuver, 10, 0.1, 0.2);
    }

    static Measurement meas(double e, double n, boolean vel) {
        return new Measurement(new double[] {e, n}, new double[] {2500, 2500}, vel, 3, 4);
    }

    public static void testFirstReport() {
        TrackEstimate t = TrackEstimate.first(params(false), meas(10, 20, false));
        Check.eq(List.of(10.0, 0.0, 2500.0, 0.0, 10000.0), t.east().toList(), "east, no velocity");
        TrackEstimate v = TrackEstimate.first(params(false), meas(10, 20, true));
        Check.eq(List.of(20.0, 4.0, 2500.0, 0.0, 25.0), v.north().toList(), "north, with velocity");
    }

    public static void testOneModelUpdateMatchesAxis() {
        TrackEstimate t = TrackEstimate.first(params(false), meas(0, 0, true));
        TrackEstimate.Updated u = t.update(1.5, meas(10, 5, true));
        Check.isTrue(u.trace == null, "no two-model trace");
        Axis want = t.east().predict(1.5, 1).updatePosition(10, 2500).updateVelocity(3, 25);
        Check.eq(want.toList(), u.estimate.east().toList(), "east");
        Check.eq(List.of(0.0, 3.0, 2500.0, 0.0, 25.0), t.east().toList(), "the first estimate unchanged");
    }

    public static void testTwoModels() {
        TrackEstimate t = TrackEstimate.first(params(true), meas(0, 0, false));
        Map<String, Object> snap = new LinkedHashMap<>();
        t.putSnapshot(snap);
        List<?> mode = (List<?>) snap.get("mode");
        Check.near(2.0 / 3, (Double) mode.get(0), 1e-15, "first mode probability pLeave/s");
        Check.near(1.0 / 3, (Double) mode.get(1), 1e-15, "second mode probability pEnter/s");
        TrackEstimate.Updated u = t.update(2, meas(30, -20, true));
        Check.near(1, u.trace[2] + u.trace[3], 1e-15, "mode probabilities sum to 1");
        Check.isTrue(u.trace[0] > u.trace[1] || u.trace[0] <= u.trace[1], "lambdas are numbers");
        Map<String, Object> s2 = new LinkedHashMap<>();
        u.estimate.putSnapshot(s2);
        Check.eq(List.of("filter", "models", "mode"), List.copyOf(s2.keySet()), "snapshot keys");
    }

    public static void testSwitching() {
        double[][] t = TrackEstimate.switching(0.1, 0.2, 0);
        Check.eq(List.of(1.0, 0.0), List.of(t[0][0], t[0][1]), "no time, no switch");
        double[][] u = TrackEstimate.switching(0.1, 0.2, 1);
        Check.near(0.1, u[0][1], 1e-15, "one second: p_enter");
        Check.near(0.2, u[1][0], 1e-15, "one second: p_leave");
    }

    public static void testModeProbabilities() {
        double[] mu = TrackEstimate.modeProbabilities(new double[] {0.5, 0}, new double[] {-1, 5});
        Check.eq(List.of(1.0, 0.0), List.of(mu[0], mu[1]), "a model with c = 0 gets 0");
    }

    public static void testBlend() {
        Axis b = TrackEstimate.blend(1, axis(), 0, new Axis(9, 9, 9, 9, 9));
        Check.eq(axis().toList(), b.toList(), "weight 1 keeps the first");
    }

    public static void testFrame() {
        double[] en = Frame.toPlane(50, 10, 50, 10);
        Check.eq(List.of(0.0, 0.0), List.of(en[0], en[1]), "reference is the origin");
        double[] p = Frame.toPlane(50, 10, 50.01, 10.02);
        double[] ll = Frame.toDegrees(50, 10, p[0], p[1]);
        Check.near(50.01, ll[0], 1e-12, "lat round trip");
        Check.near(10.02, ll[1], 1e-12, "lon round trip");
        Check.same(-170, Frame.wrapLon(190), "wrap 190");
        Check.same(180, Frame.wrapLon(-180), "wrap -180");
        double[] across = Frame.toPlane(0, 179.9, 0, -179.9);
        Check.isTrue(across[0] > 0 && across[0] < 30000, "east across the dateline: " + across[0]);
    }

    public static void testCourse() {
        Check.same(0, Frame.course(0, 1), "north");
        Check.same(90, Frame.course(1, 0), "east");
        Check.same(180, Frame.course(0, -1), "south");
        Check.same(270, Frame.course(-1, 0), "west");
        Check.same(0, Frame.course(0, 0), "still");
    }

    public static void testKeyOrderIsCodePointOrder() {
        String bmp = "￿", astral = new String(Character.toChars(0x1F600));
        Check.isTrue(KeyOrder.KEY_ORDER.compare(bmp, astral) < 0, "U+FFFF before U+1F600");
        Check.isTrue(bmp.compareTo(astral) > 0, "unlike UTF-16 order");
        Check.isTrue(KeyOrder.KEY_ORDER.compare("a", "ab") < 0, "prefix first");
        Check.isTrue(KeyOrder.KEY_ORDER.compare("B", "a") < 0, "byte order");
        Check.eq(0, KeyOrder.KEY_ORDER.compare("x/1", "x/1"), "equal");
    }

    /** The fast comparison has the sign of the definition (compare the code point arrays), surrogates included. */
    public static void testKeyOrderMatchesDefinition() {
        goat.testkit.Rng r = new goat.testkit.Rng(99);
        char[] alphabet = {'a', 'b', '/', '\u00e9', '\uD7FF', '\uD800', '\uDBFF', '\uDC00', '\uDFFF', '\uE000', '\uFFFF'};
        for (int i = 0; i < 20000; i++) {
            String x = word(r, alphabet), y = r.chance(0.3) ? x + word(r, alphabet) : word(r, alphabet);
            int want = Integer.signum(java.util.Arrays.compare(x.codePoints().toArray(), y.codePoints().toArray()));
            Check.eq(want, Integer.signum(KeyOrder.compare(x, y)), "compare " + x.chars().boxed().toList() + " " + y.chars().boxed().toList());
        }
    }

    static String word(goat.testkit.Rng r, char[] alphabet) {
        StringBuilder b = new StringBuilder();
        int n = r.below(5);
        for (int k = 0; k < n; k++) b.append(alphabet[r.below(alphabet.length)]);
        return b.toString();
    }

    static Map<String, Object> report() {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("track.source_id", "s");
        r.put("uid", "u");
        r.put("time_ms", 5L);
        r.put("lat", 1.0);
        r.put("lon", 2L);
        return r;
    }

    public static void testRequiredKeys() {
        Check.eq(null, Report.missingKey(report()), "all present");
        Check.eq("track.source_id", Report.missingKey(new HashMap<>()), "first in order");
        Map<String, Object> r = report();
        r.put("time_ms", 5.0);
        Check.eq("time_ms", Report.missingKey(r), "time_ms must be an integer");
        r = report();
        r.put("lat", "1");
        Check.eq("lat", Report.missingKey(r), "lat must be a number");
        Check.eq("s/u", Report.entityKey(report()), "entity key");
    }

    public static void testOptionalKeys() {
        Map<String, Object> r = report();
        r.put("hae", null);
        r.put("ce", 0L);
        r.put("course", "north");
        r.put("speed_ms", 3L);
        r.put("type", 7L);
        r.put("stale_ms", 1.5);
        r.put("extra", true);
        Map<String, Object> p = Report.present(r);
        Check.eq(List.of("track.source_id", "uid", "time_ms", "lat", "lon", "speed_ms", "extra"),
                List.copyOf(p.keySet()), "present keys");
    }

    public static void testTimeQuality() {
        Map<String, Map<String, Object>> defaults = new HashMap<>();
        Map<String, Object> d = new HashMap<>();
        d.put("error_ms", 40.0);
        d.put("state", "drifting");
        defaults.put("s", d);
        Map<String, Object> r = report();
        Check.same(40, Report.timeError(r, defaults), "pack default");
        Check.eq("drifting", Report.timeState(r, defaults), "pack default state");
        Check.same(0, Report.timeError(r, new HashMap<>()), "none: 0");
        Check.eq("coherent", Report.timeState(r, new HashMap<>()), "none: coherent");
        r.put("time_error_ms", 7L);
        r.put("time_state", "free-running");
        Check.same(7, Report.timeError(r, defaults), "the report's own");
        Check.eq("free-running", Report.timeState(r, defaults), "the report's own state");
        r.put("time_error_ms", -1.0);
        r.put("time_state", "Coherent");
        Check.eq(null, Report.reportTimeError(r), "negative is absent");
        Check.eq(null, Report.reportTimeState(r), "byte for byte");
        r.put("time_error_ms", Double.POSITIVE_INFINITY);
        Check.eq(null, Report.reportTimeError(r), "infinite is absent");
    }

    public static void testInverseVariance() {
        Axis a = new Axis(0, 0, 4, 1, 4), b = new Axis(10, 2, 4, 1, 4);
        Axis[] f = InverseVariance.combine(List.of(new Axis[] {a, a}, new Axis[] {b, b}));
        Check.eq(List.of(5.0, 1.0, 2.0, 0.0, 2.0), f[0].toList(), "equal weights: the mean, half the variance");
        Axis[] one = InverseVariance.combine(List.<Axis[]>of(new Axis[] {b, a}));
        Check.eq(List.of(10.0, 2.0, 4.0, 0.0, 4.0), one[0].toList(), "one member: itself, pv 0");
    }
}
