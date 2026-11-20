package goat.quality;

import goat.io.LoadError;
import goat.io.Processor;
import goat.model.Axis;
import goat.model.Frame;
import goat.model.Report;
import goat.trace.Result;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import static goat.model.KeyOrder.KEY_ORDER;

/**
 * The quality function: load_pack, ingest, tick, snapshot (spec/quality.md, version 0.2).
 * The frame and the per-entity filter are the shared model's ({@link Frame}, {@link Axis}), as
 * quality.md cites correlate.md for them, and so is the reading of a report's required and time
 * keys ({@link Report}, correlate.md 0.8, Reports and Time quality).
 */
public final class Quality implements Processor {

    // ---- state ----

    /** Spec: Samples, one report's record. Samples are null when not taken. */
    static final class Record {
        long wt, timeMs;
        String order;
        Long interval, latency;
        /** A Long when the input clock is an integer, a Double when it is a mean of two. */
        Number lateness;
        Double nis, speedErr, timeError;
        String timeState;
        boolean sourceOutOfOrder;
        boolean ce, vel, hae;

        Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("wt", wt);
            m.put("time_ms", timeMs);
            m.put("order", order);
            m.put("interval", interval);
            m.put("latency", latency);
            m.put("lateness", lateness);
            m.put("source_out_of_order", sourceOutOfOrder);
            m.put("time_error", timeError);
            m.put("time_state", timeState);
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

    private final QualityPack pack;
    private Double lat0, lon0;
    private Long lastTick;
    private final TreeMap<String, Entity> entities = new TreeMap<>(KEY_ORDER);
    /** Rule name (pack order) -> subject (key order) -> state. */
    private final LinkedHashMap<String, TreeMap<String, RuleState>> ruleStates = new LinkedHashMap<>();

    public Quality(QualityPack pack) {
        this.pack = pack;
        for (QualityPack.Rule r : pack.rules) ruleStates.put(r.name, new TreeMap<>(KEY_ORDER));
    }

    public static Quality load(java.nio.file.Path dir) throws LoadError {
        return new Quality(QualityPack.load(dir));
    }

    public static Quality fromText(String packDef) throws LoadError {
        return new Quality(QualityPack.parse(packDef));
    }

    // ---- ingest (spec: Reports, Order, Frame and filter, Samples, Ingest, Forwarding) ----

    @Override
    public Result ingest(Map<String, Object> report) {
        Result res = new Result();

        // Reports: required keys, in table order (as correlate.md, section Reports).
        String missing = Report.missingKey(report);
        if (missing != null) {
            res.events.add(ev("reject", "reason", "missing:" + missing));
            return res;
        }
        String source = (String) report.get("track.source_id");
        String key = Report.entityKey(report);
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
        double[] en = Frame.toPlane(lat0, lon0, lat, lon);
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

        // Input clock and source latest, from the entities as they are before this report.
        Number clock = inputClock(source);
        Long sourceLatest = latestOf(source);

        // Samples, in the order interval, latency, lateness, time_error, time_state,
        // source_order, nis, speed_err.
        if (order.equals("advance")) {
            rec.interval = t - last;
            res.trace.add(sample(key, "interval", rec.interval, t, last));
        }
        if (received != null) {
            rec.latency = received - t;
            res.trace.add(sample(key, "latency", rec.latency, received, t));
        }
        if (clock != null) {
            // clock - t: an integer when the clock is one, else binary64.
            rec.lateness = clock instanceof Long ? (Number) ((Long) clock - t) : (Number) (clock.doubleValue() - t);
            res.trace.add(sample(key, "lateness", rec.lateness, clock, t));
        }
        // Reports, Time quality: per key, the report's valid value, else the pack's
        // time_default for the report's own source, else unstated (no sample).
        Double ownError = Report.reportTimeError(report);
        Double defaultError = pack.defaultErrorMs.get(source);
        rec.timeError = ownError != null ? ownError : defaultError;
        if (rec.timeError != null) res.trace.add(sample(key, "time_error", rec.timeError, ownError, defaultError));
        String ownState = Report.reportTimeState(report);
        String defaultState = pack.defaultState.get(source);
        rec.timeState = ownState != null ? ownState : defaultState;
        if (rec.timeState != null) res.trace.add(sample(key, "time_state", rec.timeState, ownState, defaultState));
        // source_order: always taken.
        rec.sourceOutOfOrder = sourceLatest != null && t < sourceLatest;
        res.trace.add(sample(key, "source_order", rec.sourceOutOfOrder ? "out-of-order" : "in-order", t, sourceLatest));
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
            double c = Frame.rad(course);
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

    /**
     * Spec: Input clock. The latest time of each source other than {@code reportSource} (the
     * greatest {@code last} of the entities whose source it is), and their median: the middle
     * value (a Long) for an odd count, {@code (a + b) / 2} in binary64 (a Double) for an even
     * count; null with no other source.
     */
    private Number inputClock(String reportSource) {
        TreeMap<String, Long> latest = new TreeMap<>(KEY_ORDER);
        for (Entity ent : entities.values())
            if (!ent.source.equals(reportSource)) latest.merge(ent.source, ent.last, Math::max);
        if (latest.isEmpty()) return null;
        List<Long> times = new ArrayList<>(latest.values());
        Collections.sort(times);
        int c = times.size();
        if (c % 2 == 1) return times.get(c / 2);
        double a = times.get(c / 2 - 1), b = times.get(c / 2);
        return (a + b) / 2;
    }

    /**
     * Spec: Input clock, the source latest: the greatest {@code last} among the entities whose
     * source is {@code source} (the report's own entity included when its source is that one);
     * null when there is none.
     */
    private Long latestOf(String source) {
        Long best = null;
        for (Entity ent : entities.values())
            if (ent.source.equals(source) && (best == null || ent.last > best)) best = ent.last;
        return best;
    }

    /** Spec: Forwarding, the `pass` event for an accepted report of entity a. */
    private Map<String, Object> pass(Entity a, Map<String, Object> report, Double validCe) {
        // Actions in force other than alert, in pack order.
        List<QualityPack.Rule> inForce = new ArrayList<>();
        for (QualityPack.Rule rule : pack.rules) {
            if (rule.action.equals("alert")) continue;
            String subject = rule.scope.equals("entity") ? a.key : a.source;
            RuleState st = ruleStates.get(rule.name).get(subject);
            if (st != null && st.active) inForce.add(rule);
        }
        List<Object> names = new ArrayList<>();
        boolean drop = false, downgrade = false, mark = false;
        for (QualityPack.Rule rule : inForce) {
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
            for (QualityPack.Rule rule : inForce) if (rule.action.equals("downgrade")) x = x * rule.factor;
            // An x that overflowed to infinity is forwarded as the largest finite binary64.
            out.put("ce", Double.isInfinite(x) ? Double.MAX_VALUE : x);
        }
        if (mark) {
            List<Object> marks = new ArrayList<>();
            Object got = report.get("quality.marks");
            if (got instanceof List && ((List<?>) got).stream().allMatch(o -> o instanceof String))
                marks.addAll((List<?>) got);
            for (QualityPack.Rule rule : inForce)
                if (rule.action.equals("mark") && !marks.contains(rule.name)) marks.add(rule.name);
            out.put("quality.marks", marks);
        }
        m.put("report", out);
        return m;
    }

    // ---- tick (spec: Tick, Window, Entity measures, Source measures, Rules) ----

    @Override
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
        for (QualityPack.Rule rule : pack.rules) {
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
        List<Long> intervals = new ArrayList<>(), latencies = new ArrayList<>(), stateCodes = new ArrayList<>();
        List<Number> lateness = new ArrayList<>();
        List<Double> nis = new ArrayList<>(), speedErr = new ArrayList<>(), timeErrors = new ArrayList<>();
        long outOfOrder = 0, duplicate = 0, sourceOutOfOrder = 0, noCe = 0, noVel = 0, noHae = 0, noTime = 0;
        for (Record rec : w) {
            if (rec.interval != null) intervals.add(rec.interval);
            if (rec.latency != null) latencies.add(rec.latency);
            if (rec.lateness != null) lateness.add(rec.lateness);
            if (rec.nis != null) nis.add(rec.nis);
            if (rec.speedErr != null) speedErr.add(rec.speedErr);
            if (rec.timeError != null) timeErrors.add(rec.timeError);
            if (rec.timeState != null) stateCodes.add(stateCode(rec.timeState));
            else noTime++;
            if (rec.order.equals("out-of-order")) outOfOrder++;
            if (rec.order.equals("duplicate")) duplicate++;
            if (rec.sourceOutOfOrder) sourceOutOfOrder++;
            if (!rec.ce) noCe++;
            if (!rec.vel) noVel++;
            if (!rec.hae) noHae++;
        }
        long reports = w.size();
        boolean enoughIntervals = intervals.size() >= k, enoughLatencies = latencies.size() >= k;
        boolean enoughLateness = lateness.size() >= k, enoughErrors = timeErrors.size() >= k;
        boolean enoughStates = stateCodes.size() >= k, enoughReports = reports >= k;

        Map<String, Object> m = new LinkedHashMap<>();
        m.put("reports", reports);
        m.put("interval_last", enoughIntervals ? intervals.get(intervals.size() - 1) : null);
        m.put("interval_mean", enoughIntervals ? mean(intervals) : null);
        m.put("interval_max", enoughIntervals ? max(intervals) : null);
        m.put("age", now - ent.last);
        m.put("latency_mean", enoughLatencies ? mean(latencies) : null);
        m.put("latency_max", enoughLatencies ? max(latencies) : null);
        m.put("lateness_mean", enoughLateness ? mean(lateness) : null);
        m.put("lateness_max", enoughLateness ? max(lateness) : null);
        m.put("lateness_min", enoughLateness ? min(lateness) : null);
        m.put("nis_mean", nis.size() >= k ? mean(nis) : null);
        m.put("speed_err_mean", speedErr.size() >= k ? mean(speedErr) : null);
        m.put("out_of_order", outOfOrder);
        m.put("duplicate", duplicate);
        m.put("source_out_of_order", sourceOutOfOrder);
        m.put("missing_ce", enoughReports ? (double) noCe / reports : null);
        m.put("missing_vel", enoughReports ? (double) noVel / reports : null);
        m.put("missing_hae", enoughReports ? (double) noHae / reports : null);
        m.put("time_error_mean", enoughErrors ? mean(timeErrors) : null);
        m.put("time_error_max", enoughErrors ? max(timeErrors) : null);
        m.put("time_state_last", enoughStates ? stateCodes.get(stateCodes.size() - 1) : null);
        m.put("time_state_worst", enoughStates ? max(stateCodes) : null);
        m.put("missing_time", enoughReports ? (double) noTime / reports : null);
        return m;
    }

    /** Spec: Source measures, aggregating its entities' measures (given in key order). */
    private static Map<String, Object> sourceMeasures(List<Map<String, Object>> members) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (String name : QualityPack.ENTITY_MEASURES) {
            List<Number> present = new ArrayList<>();
            for (Map<String, Object> em : members) if (em.get(name) != null) present.add((Number) em.get(name));
            switch (name) {
                case "reports": case "out_of_order": case "duplicate": case "source_out_of_order": {
                    long s = 0;
                    for (Number x : present) s += x.longValue();
                    m.put(name, s);
                    break;
                }
                case "interval_max": case "latency_max": case "lateness_max": case "time_error_max":
                case "time_state_last": case "time_state_worst":
                    m.put(name, present.isEmpty() ? null : max(present));
                    break;
                case "lateness_min":
                    m.put(name, present.isEmpty() ? null : min(present));
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

    /**
     * The largest of a non-empty list, kept as given (an integer sample stays an integer).
     * Two integers compare exactly; any other pair compares as binary64.
     */
    private static Number max(List<? extends Number> xs) {
        Number best = xs.get(0);
        for (Number x : xs) if (compare(x, best) > 0) best = x;
        return best;
    }

    /** The smallest of a non-empty list, as {@link #max}. */
    private static Number min(List<? extends Number> xs) {
        Number best = xs.get(0);
        for (Number x : xs) if (compare(x, best) < 0) best = x;
        return best;
    }

    private static int compare(Number x, Number y) {
        if (x instanceof Long && y instanceof Long) return Long.compare((Long) x, (Long) y);
        return Double.compare(x.doubleValue(), y.doubleValue());
    }

    /** Spec: Reports, Time quality: the code of a time state (higher is worse). */
    private static long stateCode(String state) {
        switch (state) {
            case "coherent": return 0;
            case "drifting": return 1;
            default: return 2; // free-running
        }
    }

    /** Spec: Rules, Evaluation; one trace record per rule (spec: Trace). */
    private void evaluate(String scope, String subject, Map<String, Object> measures, Result res) {
        for (QualityPack.Rule rule : pack.rules) {
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

    @Override
    public Map<String, Object> snapshot() {
        Map<String, Object> s = new LinkedHashMap<>();
        s.put("ref", goat.snapshot.Snapshots.ref(lat0, lon0));
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
