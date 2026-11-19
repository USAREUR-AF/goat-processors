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
    public static final Comparator<String> KEY_ORDER = (x, y) -> Arrays.compare(
            x.codePoints().toArray(), y.codePoints().toArray());

    // Spec: Frame
    static final double R = 6371008.8;

    static double rad(double x) {
        return x * Math.PI / 180;
    }

    static double deg(double x) {
        return x * 180 / Math.PI;
    }

    static double wrapLon(double lon) {
        while (lon > 180) lon -= 360;
        while (lon <= -180) lon += 360;
        return lon;
    }

    /** Spec: Track estimate, one axis of the constant-velocity filter. */
    static final class Axis {
        double p, v, pp, pv, vv;

        Axis(double p, double v, double pp, double pv, double vv) {
            this.p = p; this.v = v; this.pp = pp; this.pv = pv; this.vv = vv;
        }

        Axis copy() {
            return new Axis(p, v, pp, pv, vv);
        }

        /** Step 1, predict. */
        void predict(double dt, double q) {
            double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
            p = p0 + v0 * dt;
            pp = pp0 + 2 * dt * pv0 + dt * dt * vv0 + q * dt * dt * dt * dt / 4;
            pv = pv0 + dt * vv0 + q * dt * dt * dt / 2;
            vv = vv0 + q * dt * dt;
        }

        /** Step 2, position update. */
        void updatePosition(double z, double r) {
            double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
            double s = pp0 + r, k1 = pp0 / s, k2 = pv0 / s, y = z - p0;
            p = p0 + k1 * y;
            v = v0 + k2 * y;
            pp = (1 - k1) * pp0;
            pv = (1 - k1) * pv0;
            vv = vv0 - k2 * pv0;
        }

        /** Step 3, velocity update. */
        void updateVelocity(double z, double r) {
            double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
            double s = vv0 + r, k1 = pv0 / s, k2 = vv0 / s, y = z - v0;
            p = p0 + k1 * y;
            v = v0 + k2 * y;
            pp = pp0 - k1 * pv0;
            pv = (1 - k2) * pv0;
            vv = (1 - k2) * vv0;
        }

        List<Object> toList() {
            return List.of(p, v, pp, pv, vv);
        }
    }

    static final class Entity {
        final String key, source;
        long lastTime;
        Axis east, north;
        Map<String, Object> last;
        double ce;
        String group;
        long holdFailures;

        Entity(String key, String source) {
            this.key = key;
            this.source = source;
        }

        Double num(String k) {
            Object o = last.get(k);
            return o instanceof Number ? ((Number) o).doubleValue() : null;
        }
    }

    /** B's filter predicted to time t (spec: Track estimate, Prediction). */
    final class Predicted {
        final Axis east, north;

        Predicted(Entity b, long t) {
            double dt = (t - b.lastTime) / 1000.0;
            east = b.east.copy();
            north = b.north.copy();
            east.predict(dt, pack.accelVar);
            north.predict(dt, pack.accelVar);
        }
    }

    private Pack pack;
    private Double lat0, lon0;
    private final TreeMap<String, Entity> entities = new TreeMap<>(KEY_ORDER);
    private final LinkedHashMap<String, TreeSet<String>> groups = new LinkedHashMap<>();
    private final TreeMap<String, Long> counts = new TreeMap<>(KEY_ORDER);
    private long nextGroup = 1;

    public Engine(Pack pack) {
        this.pack = pack;
    }

    public static Pack loadPack(java.nio.file.Path dir) throws Pack.LoadError {
        return Pack.load(dir);
    }

    // ---- ingest (spec: Reports, Track estimate, Association "On each accepted report") ----

    private static final String[] REQUIRED = {"track.source_id", "uid", "time_ms", "lat", "lon"};

    public Result ingest(Map<String, Object> report) {
        Result res = new Result();
        for (String k : REQUIRED) {
            Object o = report.get(k);
            boolean ok = k.equals("time_ms") ? o instanceof Long
                    : k.equals("lat") || k.equals("lon") ? o instanceof Number
                    : o instanceof String;
            if (!ok) {
                res.events.add(ev("reject", "reason", "missing:" + k));
                return res;
            }
        }
        String source = (String) report.get("track.source_id");
        String key = source + "/" + report.get("uid");
        long time = ((Number) report.get("time_ms")).longValue();
        Entity a = entities.get(key);
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
        double ce = ceObj instanceof Number ? ((Number) ceObj).doubleValue() : pack.defaultCe;
        Object course = report.get("course"), speed = report.get("speed_ms");
        boolean hasVel = course instanceof Number && speed instanceof Number;
        double ve = 0, vn = 0;
        if (hasVel) {
            double sp = ((Number) speed).doubleValue(), c = rad(((Number) course).doubleValue());
            ve = sp * Math.sin(c);
            vn = sp * Math.cos(c);
        }

        if (a == null) {
            // First report
            a = new Entity(key, source);
            double vv = hasVel ? pack.velSigma * pack.velSigma : pack.unknownVel * pack.unknownVel;
            a.east = new Axis(en[0], ve, ce * ce, 0, vv);
            a.north = new Axis(en[1], vn, ce * ce, 0, vv);
            entities.put(key, a);
            res.events.add(ev("new", "entity", key));
        } else {
            // Later reports
            double dt = (time - a.lastTime) / 1000.0;
            Axis[] axes = {a.east, a.north};
            double[] zv = {ve, vn};
            for (int k = 0; k < 2; k++) {
                axes[k].predict(dt, pack.accelVar);
                axes[k].updatePosition(en[k], ce * ce);
                if (hasVel) axes[k].updateVelocity(zv[k], pack.velSigma * pack.velSigma);
            }
        }
        a.lastTime = time;
        a.last = new LinkedHashMap<>(report);
        // Spec: Reports, an optional key of the wrong type is treated as absent.
        for (String k : new String[] {"hae", "ce", "course", "speed_ms"})
            if (!(a.last.get(k) instanceof Number)) a.last.remove(k);
        if (!(a.last.get("type") instanceof String)) a.last.remove("type");
        if (!(a.last.get("stale_ms") instanceof Long)) a.last.remove("stale_ms");
        a.ce = ce;

        if (a.group != null) hold(a, res);
        else associate(a, res);
        return res;
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
            double d2 = mahalanobis(a, b, new Predicted(b, a.lastTime));
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
    private boolean runTests(List<Pack.Test> tests, String stage, Entity a, Entity b, Result res) {
        Predicted pb = new Predicted(b, a.lastTime);
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
        double de = a.east.p - pb.east.p, dn = a.north.p - pb.north.p;
        return Math.sqrt(de * de + dn * dn);
    }

    /** d² = sum over east, north of (pa - pb)² / (pp_b + ce_a²). */
    private static double mahalanobis(Entity a, Entity b, Predicted pb) {
        double r = a.ce * a.ce;
        double de = a.east.p - pb.east.p, dn = a.north.p - pb.north.p;
        return de * de / (pb.east.pp + r) + dn * dn / (pb.north.pp + r);
    }

    /** `@env` is the third `-`-separated element of `type`. */
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
        Result res = new Result();
        // 1. Staleness
        for (Entity e : new ArrayList<>(entities.values())) {
            Object st = e.last.get("stale_ms");
            boolean stale = now - e.lastTime > pack.staleMs
                    || (st instanceof Long && now >= (Long) st);
            if (!stale) continue;
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
            double course = deg(Math.atan2(ve, vn));
            if (course < 0) course += 360;
            if (course >= 360) course -= 360;
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
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", lat0 == null ? null : List.of(lat0, lon0));
        Map<String, Object> ents = new LinkedHashMap<>();
        for (Entity e : entities.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("last_time_ms", e.lastTime);
            m.put("group", e.group);
            m.put("hold_failures", e.holdFailures);
            Map<String, Object> f = new LinkedHashMap<>();
            f.put("east", e.east.toList());
            f.put("north", e.north.toList());
            m.put("filter", f);
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
        double dlon = wrapLon(lon - lon0);
        return new double[] {R * rad(dlon) * Math.cos(rad(lat0)), R * rad(lat - lat0)};
    }

    private double[] toDegrees(double east, double north) {
        double lat = lat0 + deg(north / R);
        double lon = wrapLon(lon0 + deg(east / (R * Math.cos(rad(lat0)))));
        return new double[] {lat, lon};
    }

    private static String pairKey(String x, String y) {
        return KEY_ORDER.compare(x, y) <= 0 ? x + "|" + y : y + "|" + x;
    }

    private static Map<String, Object> ev(String name, Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ev", name);
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
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
