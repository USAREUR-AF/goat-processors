package filter;

import correlator.Engine.Result;
import correlator.Reports;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** The filter (spec filter.md): load_pack, ingest, tick, snapshot. */
public final class Filter {

    /** Spec: Snapshot, the stored state of one entity. */
    static final class State {
        long timeMs;
        double lat, lon;
        Double course, speedMs;
        Long staleMs;
        Long keptMs;
    }

    private final Pack pack;
    /** Entity key to state, in key order. */
    private final TreeMap<String, State> entities = new TreeMap<>(Reports.KEY_ORDER);

    public Filter(Pack pack) {
        this.pack = pack;
    }

    public static Pack loadPack(java.nio.file.Path dir) throws Pack.LoadError {
        return Pack.load(dir);
    }

    // ---- ingest (spec: Reports, Rules) ----

    public Result ingest(Map<String, Object> report) {
        Result res = new Result();
        // Reports: the required keys, checked in order; a rejected report gives no
        // trace and changes no state. The filter never rejects as out of order.
        String missing = Reports.missingKey(report);
        if (missing != null) {
            res.events.add(event("reject", "reason", "missing:" + missing));
            return res;
        }
        String key = Reports.entityKey(report);
        Map<String, Object> r = Reports.present(report);   // optional-key rules applied

        // Rules 1 and 2: the first rule whose conditions all pass decides.
        String action = pack.defaultAction, ruleName = "default";
        for (Pack.Rule rule : pack.rules) {
            boolean matches = true;
            for (Condition c : rule.conditions) {
                Outcome o = evaluate(c, r, key);
                // Conditions: `not` swaps true and false; unknown stays unknown and never passes.
                boolean pass = o.result != null && (o.result != c.negated);
                res.trace.add(ruleRecord(rule.name, key, c, o, pass));
                if (!pass) {
                    matches = false;     // the first condition that does not pass ends the rule
                    break;
                }
            }
            if (matches) {
                action = rule.action;
                ruleName = rule.name;
                break;
            }
        }

        // Rule 3: one event.
        res.events.add(event(action, "entity", key, "rule", ruleName));

        // Rule 4: state, after the decision.
        long time = (Long) r.get("time_ms");
        State s = entities.get(key);
        if (s == null) {
            s = new State();
            entities.put(key, s);
            setPosition(s, r);       // kept_ms starts null
        } else if (time >= s.timeMs) {
            setPosition(s, r);       // an older report replaces none of them
        }
        if (action.equals("keep") && (s.keptMs == null || s.keptMs < time)) s.keptMs = time;
        return res;
    }

    /** Stores time_ms, lat, lon, course, speed_ms, stale_ms of the report (absent as null). */
    private static void setPosition(State s, Map<String, Object> r) {
        s.timeMs = (Long) r.get("time_ms");
        s.lat = num(r.get("lat"));
        s.lon = num(r.get("lon"));
        s.course = r.containsKey("course") ? num(r.get("course")) : null;
        s.speedMs = r.containsKey("speed_ms") ? num(r.get("speed_ms")) : null;
        s.staleMs = (Long) r.get("stale_ms");
    }

    // ---- conditions (spec: Conditions) ----

    /** A condition's `value`, `limit` and result: TRUE, FALSE, or null for unknown. */
    private static final class Outcome {
        final Object value, limit;
        final Boolean result;

        Outcome(Object value, Object limit, Boolean result) {
            this.value = value;
            this.limit = limit;
            this.result = result;
        }
    }

    /** Evaluates one condition against the report r (present keys only) and the state before it. */
    private Outcome evaluate(Condition c, Map<String, Object> r, String key) {
        long time = (Long) r.get("time_ms");
        double lat = num(r.get("lat")), lon = num(r.get("lon"));
        switch (c.test) {
            case "circle": {
                double d = Geometry.distance(lat, lon, c.lat, c.lon);
                return new Outcome(d, c.radiusM, d <= c.radiusM);
            }
            case "polygon": {
                String where = Geometry.polygon(c.vertexLat, c.vertexLon, lat, lon);
                return new Outcome(where, null, !where.equals("outside"));
            }
            case "near": {
                State ref = entities.get(c.reference);      // the state before this report
                boolean stale = ref == null
                        || Math.abs(time - ref.timeMs) > c.maxAgeMs
                        || (ref.staleMs != null && time >= ref.staleMs);
                if (stale) return new Outcome(null, c.radiusM, null);
                double[] p = Geometry.predict(ref, time);
                double d = Geometry.distance(lat, lon, p[0], p[1]);
                return new Outcome(d, c.radiusM, d <= c.radiusM);
            }
            case "env":
                return inList(environment((String) r.get("type")), c.in);
            case "affiliation":
                return inList(affiliation((String) r.get("type")), c.in);
            case "source":
                return inList((String) r.get("track.source_id"), c.in);
            case "uid":
                return inList((String) r.get("uid"), c.in);
            case "key": {
                Object v = r.get(c.name);
                if (c.eq != null)
                    return new Outcome(v, c.eq, v == null ? null : keyEquals(v, c.eq));
                if (c.in != null) {
                    if (v == null) return new Outcome(null, c.in, null);
                    boolean any = false;
                    for (String t : c.in) any |= keyEquals(v, t);
                    return new Outcome(v, c.in, any);
                }
                return range(v, c);
            }
            case "has": {
                boolean present = r.containsKey(c.name);
                return new Outcome(present, null, present);
            }
            case "speed":
                return range(r.get("speed_ms"), c);
            case "altitude":
                return range(r.get("hae"), c);
            case "interval": {
                State s = entities.get(key);
                Long value = s == null || s.keptMs == null ? null : time - s.keptMs;
                return new Outcome(value, c.minMs, value != null && value < c.minMs);
            }
            case "order": {
                State s = entities.get(key);
                Long limit = s == null ? null : s.keptMs;
                return new Outcome(time, limit, limit != null && time < limit);
            }
            default:
                throw new AssertionError(c.test);
        }
    }

    /** env, affiliation, source, uid: true when the value is in the list; unknown when absent. */
    private static Outcome inList(String value, List<String> in) {
        return new Outcome(value, in, value == null ? null : in.contains(value));
    }

    /** Ranges: `min <= value <= max`, a missing bound is null; unknown unless value is a number. */
    private static Outcome range(Object v, Condition c) {
        List<Object> limit = Arrays.asList(c.min, c.max);
        if (!(v instanceof Number)) return new Outcome(v, limit, null);   // true/false are not numbers
        double x = num(v);
        boolean ok = (c.min == null || c.min <= x) && (c.max == null || x <= c.max);
        return new Outcome(v, limit, ok);
    }

    /** `key` equality between the report's value v and a pack text t. */
    private static boolean keyEquals(Object v, String t) {
        if (v instanceof String) return v.equals(t);
        if (v instanceof Number) return Pack.isNumber(t) && Double.parseDouble(t) == num(v);
        if (v instanceof Boolean) return t.equals((Boolean) v ? "true" : "false");
        return false;   // an array or an object is never equal
    }

    /** Reports: the environment, the third `-`-separated element of type, or null. */
    static String environment(String type) {
        if (type == null) return null;
        String[] e = type.split("-", -1);
        return e.length >= 3 ? e[2] : null;
    }

    /** Reports: the affiliation, the second element when the first is exactly `a`, or null. */
    static String affiliation(String type) {
        if (type == null) return null;
        String[] e = type.split("-", -1);
        return e.length >= 2 && e[0].equals("a") ? e[1] : null;
    }

    // ---- tick (spec: Tick) ----

    public Result tick(long nowMs) {
        Result res = new Result();
        Iterator<Map.Entry<String, State>> it = entities.entrySet().iterator();   // key order
        while (it.hasNext()) {
            Map.Entry<String, State> e = it.next();
            long value = nowMs - e.getValue().timeMs;
            boolean forget = value > pack.forgetMs;
            Map<String, Object> rec = new LinkedHashMap<>();
            rec.put("stage", "forget");
            rec.put("entity", e.getKey());
            rec.put("test", "age");
            rec.put("value", value);
            rec.put("limit", pack.forgetMs);
            rec.put("pass", forget);
            res.trace.add(rec);
            if (forget) {
                it.remove();
                res.events.add(event("forget", "entity", e.getKey()));
            }
        }
        return res;
    }

    // ---- snapshot (spec: Snapshot) ----

    public Map<String, Object> snapshot() {
        Map<String, Object> ents = new LinkedHashMap<>();
        for (Map.Entry<String, State> e : entities.entrySet()) {
            State s = e.getValue();
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("time_ms", s.timeMs);
            m.put("lat", s.lat);
            m.put("lon", s.lon);
            m.put("course", s.course);
            m.put("speed_ms", s.speedMs);
            m.put("stale_ms", s.staleMs);
            m.put("kept_ms", s.keptMs);
            ents.put(e.getKey(), m);
        }
        Map<String, Object> snap = new LinkedHashMap<>();
        snap.put("entities", ents);
        return snap;
    }

    // ---- events and trace (spec: Events, Trace) ----

    private static Map<String, Object> event(String name, Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ev", name);
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
        return m;
    }

    private static Map<String, Object> ruleRecord(String rule, String key, Condition c, Outcome o, boolean pass) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "rule");
        m.put("rule", rule);
        m.put("entity", key);
        m.put("test", c.test);
        m.put("negated", c.negated);
        m.put("value", o.value);
        m.put("limit", o.limit instanceof List ? new ArrayList<>((List<?>) o.limit) : o.limit);
        m.put("pass", pass);
        if (o.result == null) m.put("unknown", true);
        return m;
    }

    private static double num(Object o) {
        return ((Number) o).doubleValue();
    }
}
