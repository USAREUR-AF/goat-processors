package goat.property;

import goat.io.Functions;
import goat.io.Json;
import goat.io.Processor;
import goat.testkit.Check;
import goat.testkit.Fixtures;
import goat.testkit.Rng;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Property tests over every function and pack.
 *
 * <p>Determinism: the same input gives the same output, on every scenario vector and on a
 * seeded random scenario. Order independence, where the specifications say order does not
 * matter: the order of a report's keys (a JSON object), the order of correlate's once-only
 * directives (correlate.md, Pack: only the repeating directives' order is meaningful) and of the
 * filter's directives other than its rules (filter.md, Pack). Snapshot then restore: this engine
 * has no restore (no spec section defines reading a snapshot back), so there is no such property.
 */
public final class PropertyTest {
    private PropertyTest() {}

    static final List<String> FUNCTIONS = List.of("correlate", "filter", "fuse", "quality");

    /** Every scenario vector, run twice in fresh processors: the same output, byte for byte. */
    public static void testDeterministicOnVectors() throws Exception {
        int n = 0;
        for (String fn : FUNCTIONS)
            for (String pack : Fixtures.packs(fn))
                for (Map<String, Object> v : Fixtures.vectors(pack)) {
                    List<Map<String, Object>> steps = Fixtures.steps(v);
                    Check.eq(Fixtures.run(Fixtures.load(fn, pack), steps), Fixtures.run(Fixtures.load(fn, pack), steps),
                            pack + " " + v.get("name"));
                    n++;
                }
        Check.isTrue(n > 100, "vectors run: " + n);
    }

    /** A seeded random scenario: sources, objects, reports out of order, gaps, ticks. */
    static List<Map<String, Object>> randomScenario(long seed, int reports) {
        Rng r = new Rng(seed);
        List<String> sources = List.of("radar", "beacon", "net-a", "passive");
        List<Map<String, Object>> steps = new ArrayList<>();
        long t = 1000;
        for (int i = 0; i < reports; i++) {
            t += r.below(700);
            Map<String, Object> rep = new LinkedHashMap<>();
            int obj = r.below(5);
            rep.put("track.source_id", r.pick(sources));
            rep.put("uid", "T" + obj);
            rep.put("time_ms", t - (r.chance(0.1) ? r.below(3000) : 0));
            rep.put("lat", 50 + obj * 0.01 + r.unit() * 0.001);
            rep.put("lon", 10 + t / 1e7 + r.unit() * 0.001);
            if (r.chance(0.8)) rep.put("ce", (long) (5 + r.below(80)));
            if (r.chance(0.7)) {
                rep.put("course", r.unit() * 360);
                rep.put("speed_ms", r.unit() * 150);
            }
            if (r.chance(0.6)) rep.put("hae", (double) r.below(3000));
            rep.put("type", r.pick(List.of("a-f-A", "a-h-A", "a-f-S", "a-u-G", "b-x")));
            if (r.chance(0.3)) rep.put("time_error_ms", (long) r.below(300));
            if (r.chance(0.3)) rep.put("time_state", r.pick(List.of("coherent", "drifting", "free-running", "late")));
            if (r.chance(0.2)) rep.put("received_ms", t + r.below(500));
            rep.put("fuse.group", "G" + obj);
            if (r.chance(0.02)) rep.remove("lat");
            steps.add(Map.of("ingest", rep));
            if (r.chance(0.15)) steps.add(Map.of("tick", t));
        }
        steps.add(Map.of("tick", t + 400000));
        return steps;
    }

    /** Every pack on a random scenario, twice: the same output. */
    public static void testDeterministicOnRandomScenario() throws Exception {
        List<Map<String, Object>> steps = randomScenario(20261120L, 400);
        for (String fn : FUNCTIONS)
            for (String pack : Fixtures.packs(fn))
                Check.eq(Fixtures.run(Fixtures.load(fn, pack), steps), Fixtures.run(Fixtures.load(fn, pack), steps),
                        "random scenario, " + pack);
    }

    /** JSON with every object's keys sorted: equal as JSON values, whatever the key order. */
    static String canonical(Object v) {
        return Json.write(sortKeys(v));
    }

    static Object sortKeys(Object v) {
        if (v instanceof Map) {
            TreeMap<String, Object> m = new TreeMap<>();
            for (Map.Entry<?, ?> e : ((Map<?, ?>) v).entrySet()) m.put((String) e.getKey(), sortKeys(e.getValue()));
            return m;
        }
        if (v instanceof List) {
            List<Object> l = new ArrayList<>();
            for (Object x : (List<?>) v) l.add(sortKeys(x));
            return l;
        }
        return v;
    }

    static List<String> canonicalRun(Processor p, List<Map<String, Object>> steps) {
        List<String> out = new ArrayList<>();
        for (Map<String, Object> step : steps) {
            goat.trace.Result r = goat.io.Steps.apply(p, step);
            out.add(canonical(r.events) + " " + canonical(r.trace));
        }
        out.add(canonical(p.snapshot()));
        return out;
    }

    /** Every report's keys in a shuffled order: the same output as JSON values. */
    @SuppressWarnings("unchecked")
    public static void testReportKeyOrderDoesNotMatter() throws Exception {
        Rng r = new Rng(7);
        for (String fn : FUNCTIONS)
            for (String pack : Fixtures.packs(fn))
                for (Map<String, Object> v : Fixtures.vectors(pack)) {
                    List<Map<String, Object>> steps = Fixtures.steps(v), shuffled = new ArrayList<>();
                    for (Map<String, Object> s : steps) {
                        if (!s.containsKey("ingest") || !(s.get("ingest") instanceof Map)) {
                            shuffled.add(s);
                            continue;
                        }
                        List<Map.Entry<String, Object>> kv = new ArrayList<>(((Map<String, Object>) s.get("ingest")).entrySet());
                        r.shuffle(kv);
                        Map<String, Object> rep = new LinkedHashMap<>();
                        for (Map.Entry<String, Object> e : kv) rep.put(e.getKey(), e.getValue());
                        shuffled.add(Map.of("ingest", rep));
                    }
                    Check.eq(canonicalRun(Fixtures.load(fn, pack), steps), canonicalRun(Fixtures.load(fn, pack), shuffled),
                            pack + " " + v.get("name"));
                }
    }

    /**
     * A pack.def with its order-free lines moved: {@code free} lines (a set of directives) are
     * shuffled among themselves and among the others, whose relative order is kept.
     */
    static String reorder(String text, java.util.function.Predicate<String> free, Rng r) {
        List<String> fixed = new ArrayList<>(), moving = new ArrayList<>();
        for (String line : text.split("\n", -1)) {
            String t = line.strip();
            int hash = t.indexOf('#');
            String d = (hash >= 0 ? t.substring(0, hash) : t).strip().split("\\s+")[0];
            if (!d.isEmpty() && free.test(d)) moving.add(line);
            else fixed.add(line);
        }
        r.shuffle(moving);
        List<String> out = new ArrayList<>(fixed);
        for (String m : moving) out.add(r.below(out.size() + 1), m);
        return String.join("\n", out);
    }

    static void checkReordered(String fn, java.util.function.Predicate<String> free, long seed) throws Exception {
        Rng r = new Rng(seed);
        for (String pack : Fixtures.packs(fn)) {
            String text = Fixtures.packText(pack);
            for (int k = 0; k < 3; k++) {
                String moved = reorder(text, free, r);
                for (Map<String, Object> v : Fixtures.vectors(pack)) {
                    List<Map<String, Object>> steps = Fixtures.steps(v);
                    Check.eq(Fixtures.run(Functions.fromText(fn, text), steps),
                            Fixtures.run(Functions.fromText(fn, moved), steps), pack + " reordered:\n" + moved);
                }
            }
        }
    }

    /** correlate.md, Pack: the directives that appear once may come in any order. */
    public static void testCorrelateOnceOnlyDirectiveOrder() throws Exception {
        List<String> repeating = List.of("gate", "confirm", "hold", "priority", "time_default");
        checkReordered("correlate", d -> !repeating.contains(d), 11);
    }

    /** filter.md, Pack: other directives may appear in any order relative to the rules. */
    public static void testFilterDirectiveOrder() throws Exception {
        List<String> others = List.of("pack", "version", "default", "forget_ms");
        checkReordered("filter", others::contains, 13);
    }
}
