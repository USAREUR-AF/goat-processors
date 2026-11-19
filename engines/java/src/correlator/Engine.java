package correlator;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

/** The correlator: load_pack, ingest, tick, snapshot (spec: What the correlator does). */
public final class Engine {

    /** Events and trace returned by ingest and tick. */
    public static final class Result {
        public final List<Map<String, Object>> events = new ArrayList<>();
        public final List<Map<String, Object>> trace = new ArrayList<>();
    }

    /** Spec: Reports, "key order" is ascending byte order; UTF-8 byte order equals code point order. */
    public static final Comparator<String> KEY_ORDER = Reports.KEY_ORDER;

    // Spec: Frame
    public static final double R = 6371008.8;

    public static double rad(double x) {
        return x * Math.PI / 180;
    }

    public static double deg(double x) {
        return x * 180 / Math.PI;
    }

    public static double wrapLon(double lon) {
        while (lon > 180) lon -= 360;
        while (lon <= -180) lon += 360;
        return lon;
    }

    static final class Entity {
        final String key, source;
        long lastTime;
        Filter filter;
        Map<String, Object> last;
        double ce;
        /** Track estimate, Measurement variance: the last report's time error (ms), r and timing variance, east and north. */
        double timeError;
        double[] r = new double[2];
        double[] timingVar = new double[2];
        String group;
        long holdFailures;
        /** Method assign: the entity's system track in the committed membership. */
        String system;
        /** Method assign: found stale, its drop not yet committed (correlate-assign.md, Window step 1). */
        boolean retiring;

        Entity(String key, String source) {
            this.key = key;
            this.source = source;
        }

        /** Snapshot: {@code time}, the timing variance, when the last report had a time error above 0. */
        void putTimeSnapshot(Map<String, Object> m) {
            if (!(timeError > 0)) return;
            Map<String, Object> t = new LinkedHashMap<>();
            t.put("var_east", timingVar[0]);
            t.put("var_north", timingVar[1]);
            m.put("time", t);
        }

        Double num(String k) {
            Object o = last.get(k);
            return o instanceof Number ? ((Number) o).doubleValue() : null;
        }
    }

    /** B's filter predicted to time t (spec: Track estimate, Prediction). */
    static final class Predicted {
        final Filter.Axis east, north;

        Predicted(Entity b, long t) {
            Filter.Axis[] ax = b.filter.predicted((t - b.lastTime) / 1000.0);
            east = ax[0];
            north = ax[1];
        }

        /**
         * B predicted to t to be compared with another entity (Track estimate, Measurement
         * variance): B's timing variance added to the predicted pp on each axis, before any other
         * change to the prediction.
         */
        static Predicted forComparison(Entity b, long t) {
            Predicted pr = new Predicted(b, t);
            pr.east.pp = pr.east.pp + b.timingVar[0];
            pr.north.pp = pr.north.pp + b.timingVar[1];
            return pr;
        }
    }

    private final Pack pack;
    Double lat0, lon0;
    final TreeMap<String, Entity> entities = new TreeMap<>(KEY_ORDER);
    private final LinkedHashMap<String, TreeSet<String>> groups = new LinkedHashMap<>();
    private final TreeMap<String, Long> counts = new TreeMap<>(KEY_ORDER);
    private long nextGroup = 1;
    /** Method assign (correlate-assign.md), or null with method confirm. */
    private final Assign assign;
    /** correlate-assign.md, Sensor bias, or null without the {@code bias} line. */
    final Bias bias;

    public Engine(Pack pack) {
        this.pack = pack;
        this.bias = pack.bias ? new Bias(pack) : null;
        this.assign = pack.methodAssign ? new Assign(this, pack) : null;
    }

    public static Pack loadPack(java.nio.file.Path dir) throws Pack.LoadError {
        return Pack.load(dir);
    }

    // ---- ingest (spec: Reports, Track estimate, Association "On each accepted report") ----

    public Result ingest(Map<String, Object> report) {
        Result res = new Result();
        String missing = Reports.missingKey(report);
        if (missing != null) {
            res.events.add(ev("reject", "reason", "missing:" + missing));
            return res;
        }
        String source = (String) report.get("track.source_id");
        String key = Reports.entityKey(report);
        long time = ((Number) report.get("time_ms")).longValue();
        Entity a = entities.get(key);
        // correlate-assign.md, Window: after the required keys, before out-of-order.
        if (a != null && a.retiring) {
            res.events.add(ev("reject", "entity", key, "reason", "retiring"));
            return res;
        }
        if (a != null && time < a.lastTime) {
            res.events.add(ev("reject", "entity", key, "reason", "out-of-order"));
            return res;
        }

        double lat = ((Number) report.get("lat")).doubleValue();
        double lon = ((Number) report.get("lon")).doubleValue();
        if (lat0 == null) {
            lat0 = lat;
            lon0 = lon;
        }
        double[] en = toPlane(lat, lon);
        Object ceObj = report.get("ce");
        // Spec: Reports, a ce of 0 or below is treated as absent.
        boolean ceOk = ceObj instanceof Number && ((Number) ceObj).doubleValue() > 0;
        double ce = ceOk ? ((Number) ceObj).doubleValue() : pack.defaultCe;
        Object course = report.get("course"), speed = report.get("speed_ms");
        boolean hasVel = course instanceof Number && speed instanceof Number;
        double ve = 0, vn = 0;
        if (hasVel) {
            double sp = ((Number) speed).doubleValue(), c = rad(((Number) course).doubleValue());
            ve = sp * Math.sin(c);
            vn = sp * Math.cos(c);
        }

        // Track estimate, Measurement variance, with te the report's time error (Reports, Time quality).
        // The time state is found as well; correlate does not use it in this version.
        double te = Reports.timeError(report, pack.timeDefault);
        Reports.timeState(report, pack.timeDefault);
        double[] r = new double[2], timingVar = new double[2];
        if (te == 0) {
            r[0] = ce * ce;
            r[1] = ce * ce;
        } else {
            // The velocity: the entity's prediction to time_ms, or for a first report the measured
            // velocity, or 0 without one.
            double[] vel;
            if (a == null) vel = new double[] {ve, vn};
            else {
                Predicted pr = new Predicted(a, time);
                vel = new double[] {pr.east.v, pr.north.v};
            }
            double ts = te / 1000;
            for (int k = 0; k < 2; k++) {
                double moved = vel[k] * ts;
                timingVar[k] = moved * moved;
                r[k] = ce * ce + timingVar[k];
            }
            res.trace.add(timeRec(key, te, timingVar));
        }

        Filter.Measurement meas = new Filter.Measurement(en, r, hasVel, ve, vn);
        if (a == null) {
            // Track estimate (and Two-model filter), first report: no trace record.
            a = new Entity(key, source);
            a.filter = new Filter(pack, meas);
            entities.put(key, a);
            res.events.add(ev("new", "entity", key));
        } else if (pack.restart && !restartPasses(a, time, meas, res)) {
            // Restart: the filter starts again from this report as a first report. No `new` event;
            // the entity keeps its key, group, pair counts and hold failure count.
            a.filter = new Filter(pack, meas);
            if (assign != null) assign.restarted(key);
        } else {
            // Later reports; with two models, the four filter records come before any association record.
            double[] f = a.filter.update((time - a.lastTime) / 1000.0, meas);
            if (f != null) {
                res.trace.add(filterRec(a, Filter.MODEL[0], "likelihood", f[0]));
                res.trace.add(filterRec(a, Filter.MODEL[1], "likelihood", f[1]));
                res.trace.add(filterRec(a, Filter.MODEL[0], "mode", f[2]));
                res.trace.add(filterRec(a, Filter.MODEL[1], "mode", f[3]));
            }
        }
        a.lastTime = time;
        // Spec: Reports, the optional-key rules.
        a.last = Reports.present(report);
        a.ce = ce;
        // Track estimate, Measurement variance: the entity keeps this report's r and timing
        // variance (also after a restart).
        a.timeError = te;
        a.r = r;
        a.timingVar = timingVar;

        if (assign != null) {
            // correlate-assign.md: a report gives only `new` or `reject`; the tick decides.
            assign.reported(key);
            return res;
        }
        if (a.group != null) hold(a, res);
        else associate(a, res);
        return res;
    }

    /**
     * correlate.md, Restart: d² of the report against the entity predicted to its time_ms, and its
     * trace record, before any other record of the report. True when d² is below the gate.
     */
    private boolean restartPasses(Entity a, long time, Filter.Measurement meas, Result res) {
        // Not a comparison with another entity: no timing variance on the prediction.
        Predicted pr = new Predicted(a, time);
        double de = meas.z[0] - pr.east.p, dn = meas.z[1] - pr.north.p;
        double d2 = de * de / (pr.east.pp + meas.r[0]) + dn * dn / (pr.north.pp + meas.r[1]);
        boolean pass = d2 < pack.restartGate;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "filter");
        m.put("a", a.key);
        m.put("b", null);
        m.put("test", "restart");
        m.put("value", d2);
        m.put("limit", pack.restartGate);
        m.put("pass", pass);
        res.trace.add(m);
        return pass;
    }

    /** Spec: Association, "A is in a group G: hold". */
    private void hold(Entity a, Result res) {
        String g = a.group;
        boolean held = false;
        for (String m : groups.get(g)) {
            if (m.equals(a.key)) continue;
            if (runTests(pack.hold, "hold", a, entities.get(m), res)) {
                held = true;
                break;
            }
        }
        if (held) {
            a.holdFailures = 0;
            return;
        }
        a.holdFailures += 1;
        if (a.holdFailures >= pack.holdFailures) {
            a.holdFailures = 0;
            leave(a, "hold", res);
        }
    }

    /** Spec: Association, "A is not in a group: associate". */
    private void associate(Entity a, Result res) {
        List<Entity> reached = new ArrayList<>();
        for (Entity b : entities.values()) {
            if (b == a) continue;
            if (!pack.sameSourceAllow) {
                if (b.source.equals(a.source)) continue;
                if (b.group != null && groupHoldsSource(b.group, a.source)) continue;
            }
            boolean all = runTests(pack.gate, "gate", a, b, res) && runTests(pack.confirm, "confirm", a, b, res);
            String pk = pairKey(a.key, b.key);
            long count = all ? counts.getOrDefault(pk, 0L) + 1 : 0;
            counts.put(pk, count);
            boolean ok = count >= pack.confirmCount;
            res.trace.add(rec("confirm", a, b, "count", count, pack.confirmCount, ok, false));
            if (ok) reached.add(b);
        }
        Entity chosen = null;
        double best = 0;
        for (Entity b : reached) {
            double d2 = mahalanobis(a, b, Predicted.forComparison(b, a.lastTime));
            res.trace.add(rec("rank", a, b, "rank", d2, null, true, false));
            if (chosen == null || d2 < best) {
                chosen = b;
                best = d2;
            }
        }
        if (chosen == null) return;
        if (chosen.group != null) {
            groups.get(chosen.group).add(a.key);
            a.group = chosen.group;
            res.events.add(ev("join", "group", a.group, "entity", a.key));
        } else {
            String g = "g" + nextGroup++;
            TreeSet<String> members = new TreeSet<>(KEY_ORDER);
            members.add(a.key);
            members.add(chosen.key);
            groups.put(g, members);
            a.group = g;
            chosen.group = g;
            res.events.add(ev("correlate", "group", g, "members", new ArrayList<Object>(members)));
        }
        counts.put(pairKey(a.key, chosen.key), 0L);
    }

    private boolean groupHoldsSource(String g, String source) {
        for (String m : groups.get(g)) if (entities.get(m).source.equals(source)) return true;
        return false;
    }

    /** Leave a group; dissolve it when one member is left (spec: Association). */
    private void leave(Entity e, String reason, Result res) {
        String g = e.group;
        TreeSet<String> members = groups.get(g);
        members.remove(e.key);
        e.group = null;
        res.events.add(ev("leave", "group", g, "entity", e.key, "reason", reason));
        if (members.size() == 1) {
            Entity rest = entities.get(members.first());
            rest.group = null;
            rest.holdFailures = 0;
            groups.remove(g);
            res.events.add(ev("dissolve", "group", g, "entity", rest.key));
        }
    }

    // ---- tests (spec: Tests) ----

    /** Runs tests in order, stopping at the first that fails; true when all ran and passed. */
    boolean runTests(List<Pack.Test> tests, String stage, Entity a, Entity b, Result res) {
        // B's timing variance first (Track estimate, Measurement variance), then, with bias,
        // B's prediction moved into A's frame (correlate-assign.md, Sensor bias), before the test formula.
        Predicted pb = Predicted.forComparison(b, a.lastTime);
        if (bias != null) bias.moveInto(a.source, b.source, new Filter.Axis[] {pb.east, pb.north});
        for (Pack.Test t : tests) {
            Map<String, Object> r = runTest(t, stage, a, b, pb);
            res.trace.add(r);
            if (!(Boolean) r.get("pass")) return false;
        }
        return true;
    }

    private Map<String, Object> runTest(Pack.Test t, String stage, Entity a, Entity b, Predicted pb) {
        switch (t.name) {
            case "distance": {
                double d = distance(a, pb);
                return rec(stage, a, b, t.name, d, t.p("max_m"), d < t.p("max_m"), false);
            }
            case "window": {
                double d = distance(a, pb);
                double ea = clamp(a.ce, t.p("err_min_m"), t.p("err_max_m"));
                double eb = clamp(b.ce, t.p("err_min_m"), t.p("err_max_m"));
                double limit = t.p("multiplier") * Math.sqrt(ea * ea + eb * eb) + t.p("window_m");
                return rec(stage, a, b, t.name, d, limit, d < limit, false);
            }
            case "mahalanobis": {
                double d2 = mahalanobis(a, b, pb);
                return rec(stage, a, b, t.name, d2, t.p("gate"), d2 < t.p("gate"), false);
            }
            case "course": {
                Double ca = a.num("course"), cb = b.num("course");
                if (ca == null || cb == null || slow(a, b, t.p("min_speed_ms")))
                    return rec(stage, a, b, t.name, null, null, true, true);
                double diff = Math.abs(ca - cb);
                double v = Math.min(diff, 360 - diff);
                return rec(stage, a, b, t.name, v, t.p("max_deg"), v <= t.p("max_deg"), false);
            }
            case "speed": {
                if (slow(a, b, t.p("min_speed_ms")))
                    return rec(stage, a, b, t.name, null, null, true, true);
                double sa = a.num("speed_ms"), sb = b.num("speed_ms");
                double fast = Math.max(sa, sb);
                double v = fast == 0 ? 0 : Math.abs(1 - Math.min(sa, sb) / fast) * 100;
                return rec(stage, a, b, t.name, v, t.p("max_pct"), v <= t.p("max_pct"), false);
            }
            case "altitude": {
                Double ha = a.num("hae"), hb = b.num("hae");
                if (ha == null || hb == null) return rec(stage, a, b, t.name, null, null, true, true);
                double v = Math.abs(ha - hb);
                return rec(stage, a, b, t.name, v, t.p("max_m"), v <= t.p("max_m"), false);
            }
            case "same": {
                Object va = sameValue(a, t.key), vb = sameValue(b, t.key);
                return rec(stage, a, b, t.name, va, vb, sameEqual(va, vb), false);
            }
            default:
                throw new IllegalStateException("unknown test " + t.name);
        }
    }

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
    private static double mahalanobis(Entity a, Entity b, Predicted pb) {
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

    // ---- tick (spec: Association "On each tick") ----

    public Result tick(long now) {
        if (assign != null) return assign.tick(now);
        Result res = new Result();
        // 1. Staleness
        for (Entity e : new ArrayList<>(entities.values())) {
            if (!isStale(e, now)) continue;
            if (e.group != null) leave(e, "stale", res);
            entities.remove(e.key);
            counts.keySet().removeIf(k -> {
                String[] ab = k.split("\\|", 2);
                return ab[0].equals(e.key) || ab[1].equals(e.key);
            });
            res.events.add(ev("drop", "entity", e.key));
        }
        // 2. Fused output
        for (Map.Entry<String, TreeSet<String>> g : groups.entrySet()) {
            Entity primary = null;
            for (String m : g.getValue()) {
                Entity e = entities.get(m);
                if (primary == null || better(e, primary)) primary = e;
            }
            Predicted p = new Predicted(primary, now);
            double[] ll = toDegrees(p.east.p, p.north.p);
            double ve = p.east.v, vn = p.north.v;
            double course = course(ve, vn);
            Map<String, Object> f = ev("fused", "group", g.getKey(), "primary", primary.key,
                    "members", new ArrayList<Object>(g.getValue()), "lat", ll[0], "lon", ll[1],
                    "course", course, "speed_ms", Math.hypot(ve, vn));
            Double hae = primary.num("hae");
            if (hae != null) f.put("hae", hae);
            res.events.add(f);
        }
        return res;
    }

    /** True when e beats the current primary; members are visited in key order so ties keep the earlier. */
    private boolean better(Entity e, Entity cur) {
        if (pack.outputLatest) return e.lastTime > cur.lastTime;
        return priorityOf(e) < priorityOf(cur);
    }

    private long priorityOf(Entity e) {
        return pack.priority.getOrDefault(e.source, 100L);
    }

    // ---- snapshot (spec: Snapshot) ----

    public Map<String, Object> snapshot() {
        if (assign != null) return assign.snapshot();
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", lat0 == null ? null : List.of(lat0, lon0));
        Map<String, Object> ents = new LinkedHashMap<>();
        for (Entity e : entities.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("last_time_ms", e.lastTime);
            m.put("group", e.group);
            m.put("hold_failures", e.holdFailures);
            e.filter.putSnapshot(m);
            e.putTimeSnapshot(m);
            ents.put(e.key, m);
        }
        s.put("entities", ents);
        Map<String, Object> gs = new LinkedHashMap<>();
        for (Map.Entry<String, TreeSet<String>> g : groups.entrySet())
            gs.put(g.getKey(), new ArrayList<Object>(g.getValue()));
        s.put("groups", gs);
        s.put("counts", new LinkedHashMap<String, Object>(counts));
        s.put("next_group", nextGroup);
        return s;
    }

    // ---- helpers ----

    private double[] toPlane(double lat, double lon) {
        return toPlane(lat0, lon0, lat, lon);
    }

    double[] toDegrees(double east, double north) {
        return toDegrees(lat0, lon0, east, north);
    }

    /**
     * The inverse-variance combination of correlate-assign.md, fused estimate, over filters
     * already predicted to one time ({east, north} each, in the order given); pv of the result
     * is unused and 0. Fuse's `inverse_variance` method is this same estimate (fuse.md, Kinematics).
     */
    public static Filter.Axis[] inverseVariance(List<Filter.Axis[]> predicted) {
        double[] invPP = new double[2], sumP = new double[2], invVV = new double[2], sumV = new double[2];
        for (Filter.Axis[] axes : predicted) {
            for (int k = 0; k < 2; k++) {
                invPP[k] += 1 / axes[k].pp;
                sumP[k] += axes[k].p / axes[k].pp;
                invVV[k] += 1 / axes[k].vv;
                sumV[k] += axes[k].v / axes[k].vv;
            }
        }
        Filter.Axis[] out = new Filter.Axis[2];
        for (int k = 0; k < 2; k++) {
            double pp = 1 / invPP[k], vv = 1 / invVV[k];
            out[k] = new Filter.Axis(pp * sumP[k], vv * sumV[k], pp, 0, vv);
        }
        return out;
    }

    /** Spec: Frame, degrees to meters east and north of the reference (lat0, lon0). */
    public static double[] toPlane(double lat0, double lon0, double lat, double lon) {
        double dlon = wrapLon(lon - lon0);
        return new double[] {R * rad(dlon) * Math.cos(rad(lat0)), R * rad(lat - lat0)};
    }

    /** Spec: Association, On each tick, Fused output: course in [0, 360). */
    static double course(double ve, double vn) {
        double course = deg(Math.atan2(ve, vn));
        if (course < 0) course += 360;
        if (course >= 360) course -= 360;
        return course;
    }

    /** Spec: Tests, Staleness rule of On each tick. */
    boolean isStale(Entity e, long now) {
        Object st = e.last.get("stale_ms");
        return now - e.lastTime > pack.staleMs || (st instanceof Long && now >= (Long) st);
    }

    /** Spec: Frame, back to degrees. */
    public static double[] toDegrees(double lat0, double lon0, double east, double north) {
        double lat = lat0 + deg(north / R);
        double lon = wrapLon(lon0 + deg(east / (R * Math.cos(rad(lat0)))));
        return new double[] {lat, lon};
    }

    private static String pairKey(String x, String y) {
        return KEY_ORDER.compare(x, y) <= 0 ? x + "|" + y : y + "|" + x;
    }

    static Map<String, Object> ev(String name, Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ev", name);
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
        return m;
    }

    /** Track estimate, Measurement variance: the {@code time} record of a report with time error above 0. */
    private static Map<String, Object> timeRec(String key, double te, double[] timingVar) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "filter");
        m.put("a", key);
        m.put("b", null);
        m.put("test", "time");
        m.put("value", te);
        m.put("limit", null);
        m.put("pass", true);
        m.put("var_east", timingVar[0]);
        m.put("var_north", timingVar[1]);
        return m;
    }

    /** Spec: Two-model filter, Trace: one filter record. */
    private static Map<String, Object> filterRec(Entity a, String model, String test, double value) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "filter");
        m.put("a", a.key);
        m.put("b", model);
        m.put("test", test);
        m.put("value", value);
        m.put("limit", null);
        m.put("pass", true);
        return m;
    }

    /** Spec: Trace, one record. */
    private static Map<String, Object> rec(String stage, Entity a, Entity b, String test,
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
