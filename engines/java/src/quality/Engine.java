package quality;

import correlator.Filter.Axis;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import static correlator.Engine.KEY_ORDER;

/**
 * The quality function: load_pack, ingest, tick, snapshot (spec/quality.md).
 * The frame and the per-entity filter are the correlate engine's own
 * (correlator.Engine.toPlane and correlator.Filter.Axis), as quality.md cites them.
 */
public final class Engine {

    /** Events and trace returned by ingest and tick. */
    public static final class Result {
        public final List<Map<String, Object>> events = new ArrayList<>();
        public final List<Map<String, Object>> trace = new ArrayList<>();
    }

    // ---- state ----

    /** Spec: Samples, one report's record. Samples are null when not taken. */
    static final class Record {
        long wt, timeMs;
        String order;
        Long interval, latency;
        Double nis, speedErr;
        boolean ce, vel, hae;

        Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("wt", wt);
            m.put("time_ms", timeMs);
            m.put("order", order);
            m.put("interval", interval);
            m.put("latency", latency);
            m.put("nis", nis);
            m.put("speed_err", speedErr);
            m.put("ce", ce);
            m.put("vel", vel);
            m.put("hae", hae);
            return m;
        }
    }

    static final class Entity {
        final String key, source;
        /** `last`: the entity's latest accepted time (only first/advance move it). */
        long last;
        /** `last_pos`: plane position of the latest first/advance report, as reported. */
        double lastE, lastN;
        Axis east, north;
        /** The window, in arrival order. */
        final List<Record> window = new ArrayList<>();

        Entity(String key, String source) {
            this.key = key;
            this.source = source;
        }
    }

    /** Spec: Rules, per-subject state {count, active}. */
    static final class RuleState {
        long count;
        boolean active;
    }

    private final Pack pack;
    private Double lat0, lon0;
    private Long lastTick;
    private final TreeMap<String, Entity> entities = new TreeMap<>(KEY_ORDER);
    /** Rule name (pack order) -> subject (key order) -> state. */
    private final LinkedHashMap<String, TreeMap<String, RuleState>> ruleStates = new LinkedHashMap<>();

    public Engine(Pack pack) {
        this.pack = pack;
        for (Pack.Rule r : pack.rules) ruleStates.put(r.name, new TreeMap<>(KEY_ORDER));
    }

    public static Pack loadPack(java.nio.file.Path dir) throws Pack.LoadError {
        return Pack.load(dir);
    }

    // ---- ingest (spec: Reports, Order, Frame and filter, Samples, Ingest, Forwarding) ----

    private static final String[] REQUIRED = {"track.source_id", "uid", "time_ms", "lat", "lon"};

    public Result ingest(Map<String, Object> report) {
        Result res = new Result();

        // Reports: required keys, in table order (as correlate.md, section Reports).
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
        long t = (Long) report.get("time_ms");
        double lat = ((Number) report.get("lat")).doubleValue();
        double lon = ((Number) report.get("lon")).doubleValue();

        // Reports: optional keys. Null, the wrong type, or a ce of 0 or below is absent.
        Double ce = num(report, "ce");
        if (ce != null && !(ce > 0)) ce = null;
        Double course = num(report, "course"), speed = num(report, "speed_ms"), hae = num(report, "hae");
        Long received = report.get("received_ms") instanceof Long ? (Long) report.get("received_ms") : null;
        boolean hasVel = course != null && speed != null;

        // Frame: the reference is the first accepted report.
        if (lat0 == null) {
            lat0 = lat;
            lon0 = lon;
        }
        double[] en = correlator.Engine.toPlane(lat0, lon0, lat, lon);
        double e = en[0], n = en[1];

        // Order.
        Entity a = entities.get(key);
        String order = a == null ? "first" : t > a.last ? "advance" : t == a.last ? "duplicate" : "out-of-order";
        Long last = a == null ? null : a.last;
        boolean moves = order.equals("first") || order.equals("advance");
        Record rec = new Record();
        rec.wt = moves ? t : last;
        rec.timeMs = t;
        rec.order = order;
        rec.ce = ce != null;
        rec.vel = hasVel;
        rec.hae = hae != null;
        res.trace.add(sample(key, "order", order, t, last));

        // Samples, in the order interval, latency, nis, speed_err.
        if (order.equals("advance")) {
            rec.interval = t - last;
            res.trace.add(sample(key, "interval", rec.interval, t, last));
        }
        if (received != null) {
            rec.latency = received - t;
            res.trace.add(sample(key, "latency", rec.latency, received, t));
        }
        double r = (ce != null ? ce : pack.defaultCe) * (ce != null ? ce : pack.defaultCe);
        if (order.equals("advance")) {
            // nis: predict the filter to t (correlate.md, Track estimate, step 1); the
            // update below then starts from this same prediction.
            double dt = (t - last) / 1000.0;
            a.east.predict(dt, pack.accelVar);
            a.north.predict(dt, pack.accelVar);
            double de = e - a.east.p, dn = n - a.north.p;
            double se = a.east.pp + r, sn = a.north.pp + r;
            rec.nis = de * de / se + dn * dn / sn;
            res.trace.add(sample(key, "nis", rec.nis, de, dn, se, sn));

            if (speed != null) {
                double implied = Math.hypot(e - a.lastE, n - a.lastN) / dt;
                rec.speedErr = Math.abs(implied - speed);
                res.trace.add(sample(key, "speed_err", rec.speedErr, implied, speed));
            }
        }

        // Create the entity, or update its filter, last and last_pos as the order says.
        double ve = 0, vn = 0;
        if (hasVel) {
            double c = correlator.Engine.rad(course);
            ve = speed * Math.sin(c);
            vn = speed * Math.cos(c);
        }
        if (a == null) {
            // correlate.md, Track estimate, First report.
            a = new Entity(key, source);
            double vv = hasVel ? pack.velSigma * pack.velSigma : pack.unknownVel * pack.unknownVel;
            a.east = new Axis(e, ve, r, 0, vv);
            a.north = new Axis(n, vn, r, 0, vv);
            entities.put(key, a);
            res.events.add(ev("new", "entity", key));
        } else if (order.equals("advance")) {
            // correlate.md, Track estimate, Later reports, steps 2 and 3 (step 1 done above).
            double rv = pack.velSigma * pack.velSigma;
            a.east.updatePosition(e, r);
            a.north.updatePosition(n, r);
            if (hasVel) {
                a.east.updateVelocity(ve, rv);
                a.north.updateVelocity(vn, rv);
            }
        }
        if (moves) {
            a.last = t;
            a.lastE = e;
            a.lastN = n;
        }
        a.window.add(rec);

        res.events.add(pass(a, report, ce));
        return res;
    }

    /** Spec: Forwarding, the `pass` event for an accepted report of entity a. */
    private Map<String, Object> pass(Entity a, Map<String, Object> report, Double validCe) {
        // Actions in force other than alert, in pack order.
        List<Pack.Rule> inForce = new ArrayList<>();
        for (Pack.Rule rule : pack.rules) {
            if (rule.action.equals("alert")) continue;
            String subject = rule.scope.equals("entity") ? a.key : a.source;
            RuleState st = ruleStates.get(rule.name).get(subject);
            if (st != null && st.active) inForce.add(rule);
        }
        List<Object> names = new ArrayList<>();
        boolean drop = false, downgrade = false, mark = false;
        for (Pack.Rule rule : inForce) {
            names.add(rule.name);
            drop |= rule.action.equals("drop");
            downgrade |= rule.action.equals("downgrade");
            mark |= rule.action.equals("mark");
        }
        Map<String, Object> m = ev("pass", "entity", a.key, "rules", names);
        if (drop) {
            m.put("withheld", true);
            return m;
        }
        m.put("withheld", false);
        Map<String, Object> out = new LinkedHashMap<>(report);
        if (downgrade) {
            double x = validCe != null ? validCe : pack.defaultCe;
            for (Pack.Rule rule : inForce) if (rule.action.equals("downgrade")) x = x * rule.factor;
            out.put("ce", x);
        }
        if (mark) {
            List<Object> marks = new ArrayList<>();
            Object got = report.get("quality.marks");
            if (got instanceof List && ((List<?>) got).stream().allMatch(o -> o instanceof String))
                marks.addAll((List<?>) got);
            for (Pack.Rule rule : inForce)
                if (rule.action.equals("mark") && !marks.contains(rule.name)) marks.add(rule.name);
            out.put("quality.marks", marks);
        }
        m.put("report", out);
        return m;
    }

    // ---- tick (spec: Tick, Window, Entity measures, Source measures, Rules) ----

    public Result tick(long now) {
        Result res = new Result();

        // 1. Order.
        if (lastTick != null && lastTick > now) {
            res.events.add(ev("reject", "reason", "tick-out-of-order"));
            return res;
        }
        lastTick = now;

        // 2. Forget entities, key order.
        TreeSet<String> sourcesBefore = sources();
        for (Iterator<Entity> it = entities.values().iterator(); it.hasNext(); ) {
            Entity ent = it.next();
            if (now - ent.last > pack.forgetMs) {
                forgetSubject("entity", ent.key, res);
                it.remove();
                res.events.add(ev("forget", "entity", ent.key));
            }
        }
        // 3. Forget sources, key order.
        TreeSet<String> sourcesNow = sources();
        for (String src : sourcesBefore) {
            if (!sourcesNow.contains(src)) {
                forgetSubject("source", src, res);
                res.events.add(ev("forget", "source", src));
            }
        }

        // 4. Window: drop records with wt <= now - window_ms.
        for (Entity ent : entities.values()) ent.window.removeIf(rec -> rec.wt <= now - pack.windowMs);

        // 5. Entities, key order.
        TreeMap<String, Map<String, Object>> entityMeasures = new TreeMap<>(KEY_ORDER);
        for (Entity ent : entities.values()) {
            Map<String, Object> ms = entityMeasures(ent, now);
            entityMeasures.put(ent.key, ms);
            res.events.add(ev("quality", "scope", "entity", "subject", ent.key, "measures", ms));
            evaluate("entity", ent.key, ms, res);
        }
        // 6. Sources, key order.
        for (String src : sourcesNow) {
            List<Map<String, Object>> members = new ArrayList<>();
            for (Entity ent : entities.values()) if (ent.source.equals(src)) members.add(entityMeasures.get(ent.key));
            Map<String, Object> ms = sourceMeasures(members);
            res.events.add(ev("quality", "scope", "source", "subject", src, "measures", ms));
            evaluate("source", src, ms, res);
        }
        return res;
    }

    private TreeSet<String> sources() {
        TreeSet<String> s = new TreeSet<>(KEY_ORDER);
        for (Entity ent : entities.values()) s.add(ent.source);
        return s;
    }

    /** Tick steps 2 and 3: end each active rule of the scope for the subject, drop its states. */
    private void forgetSubject(String scope, String subject, Result res) {
        for (Pack.Rule rule : pack.rules) {
            if (!rule.scope.equals(scope)) continue;
            RuleState st = ruleStates.get(rule.name).remove(subject);
            if (st != null && st.active)
                res.events.add(ev("action-end", "rule", rule.name, "scope", scope, "subject", subject,
                        "action", rule.action, "reason", "forget", "value", null));
        }
    }

    /** Spec: Entity measures, over the entity's window W at this tick. */
    private Map<String, Object> entityMeasures(Entity ent, long now) {
        List<Record> w = ent.window;
        long k = pack.minSamples;
        List<Long> intervals = new ArrayList<>(), latencies = new ArrayList<>();
        List<Double> nis = new ArrayList<>(), speedErr = new ArrayList<>();
        long outOfOrder = 0, duplicate = 0, noCe = 0, noVel = 0, noHae = 0;
        for (Record rec : w) {
            if (rec.interval != null) intervals.add(rec.interval);
            if (rec.latency != null) latencies.add(rec.latency);
            if (rec.nis != null) nis.add(rec.nis);
            if (rec.speedErr != null) speedErr.add(rec.speedErr);
            if (rec.order.equals("out-of-order")) outOfOrder++;
            if (rec.order.equals("duplicate")) duplicate++;
            if (!rec.ce) noCe++;
            if (!rec.vel) noVel++;
            if (!rec.hae) noHae++;
        }
        long reports = w.size();
        boolean enoughIntervals = intervals.size() >= k, enoughLatencies = latencies.size() >= k;
        boolean enoughReports = reports >= k;

        Map<String, Object> m = new LinkedHashMap<>();
        m.put("reports", reports);
        m.put("interval_last", enoughIntervals ? intervals.get(intervals.size() - 1) : null);
        m.put("interval_mean", enoughIntervals ? mean(intervals) : null);
        m.put("interval_max", enoughIntervals ? max(intervals) : null);
        m.put("age", now - ent.last);
        m.put("latency_mean", enoughLatencies ? mean(latencies) : null);
        m.put("latency_max", enoughLatencies ? max(latencies) : null);
        m.put("nis_mean", nis.size() >= k ? mean(nis) : null);
        m.put("speed_err_mean", speedErr.size() >= k ? mean(speedErr) : null);
        m.put("out_of_order", outOfOrder);
        m.put("duplicate", duplicate);
        m.put("missing_ce", enoughReports ? (double) noCe / reports : null);
        m.put("missing_vel", enoughReports ? (double) noVel / reports : null);
        m.put("missing_hae", enoughReports ? (double) noHae / reports : null);
        return m;
    }

    /** Spec: Source measures, aggregating its entities' measures (given in key order). */
    private static Map<String, Object> sourceMeasures(List<Map<String, Object>> members) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (String name : Pack.ENTITY_MEASURES) {
            List<Number> present = new ArrayList<>();
            for (Map<String, Object> em : members) if (em.get(name) != null) present.add((Number) em.get(name));
            switch (name) {
                case "reports": case "out_of_order": case "duplicate": {
                    long s = 0;
                    for (Number x : present) s += x.longValue();
                    m.put(name, s);
                    break;
                }
                case "interval_max": case "latency_max":
                    m.put(name, present.isEmpty() ? null : max(present));
                    break;
                case "age": {
                    long min = Long.MAX_VALUE;
                    for (Number x : present) min = Math.min(min, x.longValue());
                    m.put(name, min);
                    break;
                }
                default:
                    m.put(name, present.isEmpty() ? null : mean(present));
            }
        }
        m.put("entities", (long) members.size());
        return m;
    }

    /** Spec: Entity measures, a mean is s / n with s summed from 0.0 in order, in binary64. */
    private static double mean(List<? extends Number> xs) {
        double s = 0.0;
        for (Number x : xs) s += x.doubleValue();
        return s / xs.size();
    }

    /** The largest of integer samples (interval, latency). */
    private static Long max(List<? extends Number> xs) {
        long best = Long.MIN_VALUE;
        for (Number x : xs) best = Math.max(best, x.longValue());
        return best;
    }

    /** Spec: Rules, Evaluation; one trace record per rule (spec: Trace). */
    private void evaluate(String scope, String subject, Map<String, Object> measures, Result res) {
        for (Pack.Rule rule : pack.rules) {
            if (!rule.scope.equals(scope)) continue;
            RuleState st = ruleStates.get(rule.name).computeIfAbsent(subject, s -> new RuleState());
            Object v = measures.get(rule.measure);
            boolean wasActive = st.active;
            boolean pass;
            if (!wasActive) {
                pass = v != null && rule.meets(((Number) v).doubleValue());
                st.count = pass ? st.count + 1 : 0;
                if (st.count >= rule.forN) {
                    st.active = true;
                    st.count = 0;
                }
            } else {
                pass = v != null && rule.clears(((Number) v).doubleValue());
                if (pass) st.active = false;
            }
            Map<String, Object> tr = new LinkedHashMap<>();
            tr.put("stage", "rule");
            tr.put("rule", rule.name);
            tr.put("subject", subject);
            tr.put("measure", rule.measure);
            tr.put("value", v);
            tr.put("limit", wasActive ? rule.clear : rule.limit);
            tr.put("pass", pass);
            tr.put("count", st.count);
            tr.put("active", st.active);
            res.trace.add(tr);
            if (!wasActive && st.active)
                res.events.add(ev("action-start", "rule", rule.name, "scope", scope, "subject", subject,
                        "action", rule.action, "value", v));
            else if (wasActive && !st.active)
                res.events.add(ev("action-end", "rule", rule.name, "scope", scope, "subject", subject,
                        "action", rule.action, "reason", "clear", "value", v));
        }
    }

    // ---- snapshot (spec: Snapshot) ----

    public Map<String, Object> snapshot() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", lat0 == null ? null : List.of(lat0, lon0));
        s.put("last_tick", lastTick);
        Map<String, Object> ents = new LinkedHashMap<>();
        for (Entity ent : entities.values()) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("source", ent.source);
            m.put("last_time_ms", ent.last);
            m.put("last_pos", List.of(ent.lastE, ent.lastN));
            Map<String, Object> f = new LinkedHashMap<>();
            f.put("east", ent.east.toList());
            f.put("north", ent.north.toList());
            m.put("filter", f);
            List<Object> w = new ArrayList<>();
            for (Record rec : ent.window) w.add(rec.toMap());
            m.put("window", w);
            ents.put(ent.key, m);
        }
        s.put("entities", ents);
        Map<String, Object> rules = new LinkedHashMap<>();
        for (Map.Entry<String, TreeMap<String, RuleState>> e : ruleStates.entrySet()) {
            Map<String, Object> bySubject = new LinkedHashMap<>();
            for (Map.Entry<String, RuleState> st : e.getValue().entrySet()) {
                Map<String, Object> m = new LinkedHashMap<>();
                m.put("count", st.getValue().count);
                m.put("active", st.getValue().active);
                bySubject.put(st.getKey(), m);
            }
            rules.put(e.getKey(), bySubject);
        }
        s.put("rules", rules);
        return s;
    }

    // ---- helpers ----

    /** A number-valued optional key, or null; a boolean is never a number. */
    private static Double num(Map<String, Object> report, String k) {
        Object o = report.get(k);
        return o instanceof Number ? ((Number) o).doubleValue() : null;
    }

    /** Spec: Trace, an ingest sample record. */
    private static Map<String, Object> sample(String entity, String name, Object value, Object... inputs) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "sample");
        m.put("entity", entity);
        m.put("sample", name);
        m.put("value", value);
        List<Object> in = new ArrayList<>();
        for (Object x : inputs) in.add(x);
        m.put("inputs", in);
        return m;
    }

    private static Map<String, Object> ev(String name, Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ev", name);
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
        return m;
    }
}
