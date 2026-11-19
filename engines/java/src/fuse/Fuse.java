package fuse;

import correlator.Engine;
import correlator.Filter.Axis;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;

/**
 * The fuse engine: load_pack, ingest, tick, snapshot (spec/fuse.md). The filter, the frame and
 * the inverse-variance estimate are the correlate engine's own (correlate.md, Frame and Track
 * estimate; correlate-assign.md, fused estimate), which fuse.md cites unchanged.
 */
public final class Fuse {

    /** Events and trace returned by ingest and tick. */
    public static final class Result {
        public final List<Map<String, Object>> events = new ArrayList<>();
        public final List<Map<String, Object>> trace = new ArrayList<>();
    }

    /** One entity: its filter and its last normalised report. */
    static final class Entity {
        final String key, source;
        long lastTime;
        Axis east, north;
        /** The last normalised report (Reports). Every later value fuse reads comes from here. */
        Map<String, Object> report;
        /** The `fuse.group` of the last accepted report, or null (Groups). */
        String group;

        Entity(String key, String source) {
            this.key = key;
            this.source = source;
        }

        Object hae() {
            return report.get("hae");
        }
    }

    /** A member's filter predicted to the tick time (On each tick, step 2.1). */
    static final class Member {
        final Entity e;
        final Axis east, north;

        Member(Entity e, Axis east, Axis north) {
            this.e = e;
            this.east = east;
            this.north = north;
        }

        /** Kinematics: position variance `var = ppe + ppn`. */
        double var() {
            return east.pp + north.pp;
        }
    }

    /** One group at a tick: its name (null for an unnamed group) and its members in key order. */
    static final class Group {
        final String name;
        final List<Entity> members = new ArrayList<>();

        Group(String name) {
            this.name = name;
        }
    }

    private final FusePack pack;
    private Double lat0, lon0;
    private final TreeMap<String, Entity> entities = new TreeMap<>(Engine.KEY_ORDER);

    public Fuse(FusePack pack) {
        this.pack = pack;
    }

    public static FusePack loadPack(java.nio.file.Path dir) throws FusePack.LoadError {
        return FusePack.load(dir);
    }

    // ================================================================ ingest

    /** Reports: the required keys, checked in the order of correlate.md's table. */
    private static final String[] REQUIRED = {"track.source_id", "uid", "time_ms", "lat", "lon"};

    public Result ingest(Map<String, Object> report) {
        Result res = new Result();

        // Reports: a missing required key rejects the report.
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
        long time = (Long) report.get("time_ms");

        // Reports: a report earlier than its entity's last accepted report is ignored.
        Entity a = entities.get(key);
        if (a != null && time < a.lastTime) {
            res.events.add(ev("stale-report", "entity", key, "time_ms", time, "last_time_ms", a.lastTime));
            return res;
        }

        Map<String, Object> norm = normalise(report);

        // correlate.md, Frame: the first accepted report sets the reference.
        double lat = ((Number) norm.get("lat")).doubleValue();
        double lon = ((Number) norm.get("lon")).doubleValue();
        if (lat0 == null) {
            lat0 = lat;
            lon0 = lon;
        }
        double[] en = Engine.toPlane(lat0, lon0, lat, lon);

        // correlate.md, Track estimate: measurements from the normalised report.
        double ce = norm.containsKey("ce") ? ((Number) norm.get("ce")).doubleValue() : pack.defaultCe;
        boolean hasVel = norm.containsKey("course") && norm.containsKey("speed_ms");
        double ve = 0, vn = 0;
        if (hasVel) {
            double sp = ((Number) norm.get("speed_ms")).doubleValue();
            double c = Engine.rad(((Number) norm.get("course")).doubleValue());
            ve = sp * Math.sin(c);
            vn = sp * Math.cos(c);
        }

        String group = (String) norm.get("fuse.group");
        if (a == null) {
            // First report.
            a = new Entity(key, source);
            double vv = hasVel ? pack.velSigma * pack.velSigma : pack.unknownVel * pack.unknownVel;
            a.east = new Axis(en[0], ve, ce * ce, 0, vv);
            a.north = new Axis(en[1], vn, ce * ce, 0, vv);
            a.lastTime = time;
            a.report = norm;
            a.group = group;
            entities.put(key, a);
            res.events.add(ev("new", "entity", key, "group", group));
            return res;
        }

        // Later reports: predict, position update, velocity update (dt may be 0).
        double dt = (time - a.lastTime) / 1000.0;
        Axis[] axes = {a.east, a.north};
        double[] zv = {ve, vn};
        for (int k = 0; k < 2; k++) {
            axes[k].predict(dt, pack.accelVar);
            axes[k].updatePosition(en[k], ce * ce);
            if (hasVel) axes[k].updateVelocity(zv[k], pack.velSigma * pack.velSigma);
        }
        a.lastTime = time;
        a.report = norm;

        // Groups: a move is applied when the report is accepted, after the filter update.
        if (!Objects.equals(a.group, group)) {
            res.events.add(ev("move", "entity", key, "from", a.group, "to", group));
            a.group = group;
        }
        return res;
    }

    /**
     * Reports, the normalised report: every key removed that is null, or that correlate.md
     * Reports treats as absent (an optional key of the wrong type, a ce of 0 or below), or an
     * unusable `fuse.group` (not a string, or the empty string).
     */
    static Map<String, Object> normalise(Map<String, Object> report) {
        Map<String, Object> n = new LinkedHashMap<>(report);
        n.values().removeIf(Objects::isNull);
        for (String k : new String[] {"hae", "ce", "course", "speed_ms"})
            if (n.containsKey(k) && !(n.get(k) instanceof Number)) n.remove(k);
        if (n.containsKey("ce") && !(((Number) n.get("ce")).doubleValue() > 0)) n.remove("ce");
        if (n.containsKey("type") && !(n.get("type") instanceof String)) n.remove("type");
        if (n.containsKey("stale_ms") && !(n.get("stale_ms") instanceof Long)) n.remove("stale_ms");
        Object g = n.get("fuse.group");
        if (g != null && !(g instanceof String && !((String) g).isEmpty())) n.remove("fuse.group");
        return n;
    }

    // ================================================================ tick

    public Result tick(long now) {
        Result res = new Result();

        // Step 1, staleness, entities in key order.
        for (Entity e : new ArrayList<>(entities.values())) {
            Object reportStale = e.report.get("stale_ms");
            boolean stale = now - e.lastTime > pack.staleMs
                    || (reportStale != null && now >= (Long) reportStale);
            if (stale) {
                entities.remove(e.key);
                res.events.add(ev("drop", "entity", e.key, "group", e.group));
            }
        }

        // Step 2, fused output, groups in output order.
        for (Group g : groupsInOutputOrder()) fuseGroup(g, now, res);
        return res;
    }

    /**
     * Groups, output order: named groups in byte order of their name, then the unnamed groups
     * (one member each) in key order of that member. Members are in key order.
     */
    private List<Group> groupsInOutputOrder() {
        TreeMap<String, Group> named = new TreeMap<>(Engine.KEY_ORDER);
        List<Group> unnamed = new ArrayList<>();
        for (Entity e : entities.values()) {
            if (e.group == null) {
                Group g = new Group(null);
                g.members.add(e);
                unnamed.add(g);
            } else {
                named.computeIfAbsent(e.group, Group::new).members.add(e);
            }
        }
        List<Group> out = new ArrayList<>(named.values());
        out.addAll(unnamed);
        return out;
    }

    /** On each tick, step 2, for one group. */
    private void fuseGroup(Group g, long now, Result res) {
        // 2.1 Predict every member's filter to now_ms.
        List<Member> members = new ArrayList<>();
        for (Entity e : g.members) {
            double dt = (now - e.lastTime) / 1000.0;
            Axis east = e.east.copy(), north = e.north.copy();
            east.predict(dt, pack.accelVar);
            north.predict(dt, pack.accelVar);
            members.add(new Member(e, east, north));
        }

        // 2.2 Combine by the pack's kinematics method.
        Axis[] fused;
        Member from = null;
        switch (pack.kinematics) {
            case "inverse_variance": fused = inverseVariance(members); break;
            case "covariance_intersection": fused = covarianceIntersection(g, members, res); break;
            default:
                from = pick(members);
                fused = new Axis[] {from.east, from.north};
        }
        res.trace.add(kinematicsRecord(g, members, from));

        // 2.3 Decide every attribute, in pack order.
        Map<String, Object> attributes = new LinkedHashMap<>();
        for (FusePack.Attribute at : pack.attributes) decideAttribute(g, at, attributes, res);

        // 2.4 The fused event.
        res.events.add(fusedEvent(g, fused, from, attributes));
    }

    // ================================================================ kinematics

    /** Kinematics, rank: the index of the source among the pack's source lines, or null. */
    private Long rank(Entity e) {
        int i = pack.sources.indexOf(e.source);
        return i < 0 ? null : (long) i;
    }

    /** Rank for comparison: an unlisted source ranks after every listed one. */
    private long rankOrder(Entity e) {
        Long r = rank(e);
        return r == null ? pack.sources.size() : r;
    }

    /** `inverse_variance`: correlate-assign.md's fused estimate, members in key order. */
    private static Axis[] inverseVariance(List<Member> members) {
        List<Axis[]> predicted = new ArrayList<>();
        for (Member m : members) predicted.add(new Axis[] {m.east, m.north});
        return Engine.inverseVariance(predicted);
    }

    /** `covariance_intersection`: fold the members in key order; one trace record per fold. */
    private static Axis[] covarianceIntersection(Group g, List<Member> members, Result res) {
        Member first = members.get(0);
        Axis xe = first.east.copy(), xn = first.north.copy();
        for (Member y : members.subList(1, members.size())) {
            double w = intersectionWeight(xe.pp, xn.pp, y.east.pp, y.north.pp);
            res.trace.add(rec("stage", "intersect", "group", g.name, "member", y.e.key, "value", w));
            if (w == 1) continue; // X unchanged
            if (w == 0) {         // Y unchanged
                xe = y.east.copy();
                xn = y.north.copy();
                continue;
            }
            xe = fold(w, xe, y.east);
            xn = fold(w, xn, y.north);
        }
        return new Axis[] {xe, xn};
    }

    /** Covariance intersection, Weight: the closed form, steps 1 to 5 in order. */
    static double intersectionWeight(double xppe, double xppn, double yppe, double yppn) {
        double ae = 1 / yppe, an = 1 / yppn;            // 1
        double de = 1 / xppe - ae, dn = 1 / xppn - an;  // 2
        double c2 = de * dn;                            // 3
        double c1 = ae * dn + an * de;                  // 4
        double w;                                       // 5
        if (c2 < 0) {
            w = -c1 / (2 * c2);
            if (w < 0) w = 0;
            if (w > 1) w = 1;
        } else if (c1 + c2 > 0) {
            w = 1;
        } else if (c1 + c2 < 0) {
            w = 0;
        } else {
            w = 0.5;
        }
        return w;
    }

    /** Covariance intersection, Fold, one axis; pv of the result is unused and 0. */
    private static Axis fold(double w, Axis x, Axis y) {
        double a = w / x.pp, b = (1 - w) / y.pp, pp = 1 / (a + b);
        double p = pp * (a * x.p + b * y.p);
        double c = w / x.vv, d = (1 - w) / y.vv, vv = 1 / (c + d);
        double v = vv * (c * x.v + d * y.v);
        return new Axis(p, v, pp, 0, vv);
    }

    /** `best`, `priority`, `latest`: the one member whose filter is the estimate; ties to key order. */
    private Member pick(List<Member> members) {
        Member win = null;
        for (Member m : members) {
            if (win == null) { win = m; continue; }
            boolean better;
            switch (pack.kinematics) {
                case "best": better = m.var() < win.var(); break;
                case "priority": better = rankOrder(m.e) < rankOrder(win.e); break;
                case "latest": better = m.e.lastTime > win.e.lastTime; break;
                default: throw new IllegalStateException(pack.kinematics);
            }
            if (better) win = m;
        }
        return win;
    }

    /** Trace 2, the kinematics record. */
    private Map<String, Object> kinematicsRecord(Group g, List<Member> members, Member from) {
        List<Object> cands = new ArrayList<>();
        for (Member m : members)
            cands.add(rec("member", m.e.key, "var", m.var(), "time_ms", m.e.lastTime, "rank", rank(m.e)));
        return rec("stage", "kinematics", "group", g.name, "method", pack.kinematics,
                "candidates", cands, "winner", from == null ? null : from.e.key);
    }

    // ================================================================ attributes

    /** Attributes: decide one attribute line for a group; trace record 3. */
    private void decideAttribute(Group g, FusePack.Attribute at, Map<String, Object> out, Result res) {
        boolean numeric = at.rule.equals("max") || at.rule.equals("min");
        List<Entity> cands = new ArrayList<>();
        for (Entity e : g.members) {
            Object v = e.report.get(at.key);
            boolean usable = v instanceof Number || (!numeric && (v instanceof String || v instanceof Boolean));
            if (usable) cands.add(e);
        }

        Entity win = cands.isEmpty() ? null : at.rule.equals("majority") ? majority(cands, at.key) : null;
        if (!cands.isEmpty() && !at.rule.equals("majority")) {
            for (Entity c : cands) {
                if (win == null) { win = c; continue; }
                boolean better;
                switch (at.rule) {
                    case "priority": better = rankOrder(c) < rankOrder(win); break;
                    case "latest": better = c.lastTime > win.lastTime; break;
                    case "max": better = compare(c.report.get(at.key), win.report.get(at.key)) > 0; break;
                    case "min": better = compare(c.report.get(at.key), win.report.get(at.key)) < 0; break;
                    default: throw new IllegalStateException(at.rule);
                }
                if (better) win = c;
            }
        }

        List<Object> trace = new ArrayList<>();
        for (Entity c : cands)
            trace.add(rec("member", c.key, "value", c.report.get(at.key), "time_ms", c.lastTime, "rank", rank(c)));
        Object value = win == null ? null : win.report.get(at.key);
        res.trace.add(rec("stage", "attribute", "group", g.name, "key", at.key, "rule", at.rule,
                "candidates", trace, "winner", win == null ? null : win.key, "value", value));
        if (win != null) out.put(at.key, rec("value", value, "from", win.key));
    }

    /**
     * `majority`: the value held by the most candidates; between equal counts, the value whose
     * first holder in key order comes first. The winner is that first holder.
     */
    private static Entity majority(List<Entity> cands, String key) {
        Entity win = null;
        int best = 0;
        for (int i = 0; i < cands.size(); i++) {
            Object v = cands.get(i).report.get(key);
            boolean firstHolder = true;
            for (int j = 0; j < i; j++)
                if (majorityEqual(cands.get(j).report.get(key), v)) { firstHolder = false; break; }
            if (!firstHolder) continue;
            int count = 0;
            for (Entity c : cands) if (majorityEqual(c.report.get(key), v)) count++;
            if (count > best) { best = count; win = cands.get(i); }
        }
        return win;
    }

    /** Attributes, equality for `majority`: same string bytes, same number value, same boolean. */
    static boolean majorityEqual(Object x, Object y) {
        if (x instanceof String && y instanceof String) return x.equals(y);
        if (x instanceof Boolean && y instanceof Boolean) return x.equals(y);
        if (x instanceof Number && y instanceof Number) return compare(x, y) == 0;
        return false;
    }

    /** Numbers by value; two integers exactly, otherwise as binary64 (an open point above 2^53). */
    static int compare(Object x, Object y) {
        if (x instanceof Long && y instanceof Long) return Long.compare((Long) x, (Long) y);
        double a = ((Number) x).doubleValue(), b = ((Number) y).doubleValue();
        return a < b ? -1 : a > b ? 1 : 0;
    }

    // ================================================================ fused event

    /** Fused event, with Height. */
    private Map<String, Object> fusedEvent(Group g, Axis[] f, Member from, Map<String, Object> attributes) {
        double[] ll = Engine.toDegrees(lat0, lon0, f[0].p, f[1].p);
        double course = Engine.deg(Math.atan2(f[0].v, f[1].v));
        if (course < 0) course += 360;
        if (course >= 360) course -= 360;
        List<Object> keys = new ArrayList<>();
        for (Entity e : g.members) keys.add(e.key);

        Map<String, Object> m = ev("fused", "group", g.name, "members", keys,
                "from", from == null ? null : from.e.key,
                "lat", ll[0], "lon", ll[1], "course", course,
                "speed_ms", Math.hypot(f[0].v, f[1].v),
                "ce", Math.sqrt((f[0].pp + f[1].pp) / 2));
        Entity height = heightFrom(g, from);
        if (height != null) {
            m.put("hae", height.hae());
            m.put("hae_from", height.key);
        }
        m.put("attributes", attributes);
        return m;
    }

    /**
     * Height: for best, priority, latest the member the kinematics came from, when it has hae;
     * for inverse_variance and covariance_intersection the member with hae and the greatest
     * last_time_ms, ties to key order.
     */
    private static Entity heightFrom(Group g, Member from) {
        if (from != null) return from.e.hae() != null ? from.e : null;
        Entity win = null;
        for (Entity e : g.members)
            if (e.hae() != null && (win == null || e.lastTime > win.lastTime)) win = e;
        return win;
    }

    // ================================================================ snapshot

    public Map<String, Object> snapshot() {
        Map<String, Object> ents = new LinkedHashMap<>();
        for (Entity e : entities.values()) {
            Map<String, Object> filter = rec("east", e.east.toList(), "north", e.north.toList());
            ents.put(e.key, rec("last_time_ms", e.lastTime, "group", e.group, "filter", filter,
                    "report", new LinkedHashMap<>(e.report)));
        }
        return rec("ref", lat0 == null ? null : List.of(lat0, lon0), "entities", ents);
    }

    // ================================================================ helpers

    private static Map<String, Object> ev(String name, Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ev", name);
        m.putAll(rec(kv));
        return m;
    }

    private static Map<String, Object> rec(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
        return m;
    }
}
