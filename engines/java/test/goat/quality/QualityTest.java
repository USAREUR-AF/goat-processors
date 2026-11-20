package goat.quality;

import goat.io.LoadError;
import goat.testkit.Check;
import goat.trace.Result;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Unit tests of the quality module: the measures table and its functions, the pack, the processor. */
public final class QualityTest {
    private QualityTest() {}

    static final String PACK = "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
            + "window window_ms=60000 min_samples=2 forget_ms=300000\n"
            + "rule slow scope=entity measure=interval_mean op=> limit=1500 for=1 clear=1000 action=mark\n";

    public static void testMeanMaxMin() {
        Check.same(2.0, Measures.mean(List.of(1L, 2L, 3L)), "mean");
        Check.eq(3L, Measures.max(List.of(1L, 3L, 2L)), "max keeps an integer");
        Check.eq(2.5, Measures.max(List.of(1L, 2.5, 2L)), "max as given");
        Check.eq(-1L, Measures.min(List.of(1L, -1L)), "min");
        Check.eq(-1, Measures.compare(9007199254740992L, 9007199254740993L), "integers exactly");
        Check.eq(2L, Measures.stateCode("free-running"), "state codes");
    }

    public static void testAggregates() {
        List<Number> xs = List.of(2L, 4L);
        Check.eq(6L, Measures.aggregate(Measures.Aggregate.SUM, xs), "sum");
        Check.eq(4L, Measures.aggregate(Measures.Aggregate.MAX, xs), "max");
        Check.eq(2L, Measures.aggregate(Measures.Aggregate.MIN, xs), "min");
        Check.eq(2L, Measures.aggregate(Measures.Aggregate.LEAST, xs), "least");
        Check.eq(3.0, Measures.aggregate(Measures.Aggregate.MEAN, xs), "mean");
        Check.eq(null, Measures.aggregate(Measures.Aggregate.MEAN, List.of()), "mean of none");
        Check.eq(0L, Measures.aggregate(Measures.Aggregate.SUM, List.of()), "sum of none");
    }

    static Record rec(String order, Long interval, String state) {
        Record r = new Record();
        r.order = order;
        r.interval = interval;
        r.timeState = state;
        r.ce = true;
        return r;
    }

    public static void testEntityMeasures() {
        List<Record> w = new ArrayList<>(List.of(rec("first", null, null), rec("advance", 1000L, "coherent"),
                rec("advance", 3000L, "drifting"), rec("duplicate", null, null)));
        Map<String, Object> m = Measures.STANDARD.entity(new Measures.Window(w, 5000, 9000, 2));
        Check.eq(Measures.STANDARD.entityNames(), List.copyOf(m.keySet()), "table order");
        Check.eq(4L, m.get("reports"), "reports");
        Check.eq(3000L, m.get("interval_last"), "interval_last");
        Check.eq(2000.0, m.get("interval_mean"), "interval_mean");
        Check.eq(4000L, m.get("age"), "age");
        Check.eq(null, m.get("latency_mean"), "too few latencies");
        Check.eq(1L, m.get("duplicate"), "duplicate");
        Check.eq(0.0, m.get("missing_ce"), "missing_ce");
        Check.eq(1L, m.get("time_state_last"), "time_state_last");
        Check.eq(0.5, m.get("missing_time"), "missing_time");
    }

    public static void testSourceMeasures() {
        Map<String, Object> a = Measures.STANDARD.entity(new Measures.Window(List.of(rec("first", null, null)), 0, 10, 1));
        Map<String, Object> b = Measures.STANDARD.entity(new Measures.Window(List.of(rec("first", null, null)), 4, 10, 1));
        Map<String, Object> s = Measures.STANDARD.source(List.of(a, b));
        Check.eq(Measures.STANDARD.sourceNames(), List.copyOf(s.keySet()), "entity measures, then entities");
        Check.eq(2L, s.get("reports"), "sum");
        Check.eq(6L, s.get("age"), "least age");
        Check.eq(2L, s.get("entities"), "entities");
    }

    public static void testMeasureTableExtends() {
        Measures more = Measures.STANDARD.with(new Measures.Measure("ones", w -> 1L, Measures.Aggregate.SUM));
        Check.eq("ones", more.entityNames().get(more.entityNames().size() - 1), "added last");
        Check.isTrue(!Measures.STANDARD.entityNames().contains("ones"), "the standard table unchanged");
        Check.throwsA(LoadError.class, () -> QualityPack.parse(PACK.replace("interval_mean", "ones")), "unknown measure");
        try {
            QualityPack.parse(PACK.replace("interval_mean", "ones"), more);
        } catch (LoadError e) {
            throw new AssertionError("a registered measure loads: " + e.getMessage());
        }
    }

    public static void testMedian() {
        Check.eq(null, Quality.median(List.of()), "none");
        Check.eq(5L, Quality.median(List.of(9L, 1L, 5L)), "odd: the middle, an integer");
        Check.eq(4.0, Quality.median(List.of(9L, 1L, 3L, 5L)), "even: the mean of the two middle, binary64");
    }

    public static void testPackErrors() {
        for (String bad : List.of(
                PACK.replace("scope=entity", "scope=group"),
                PACK.replace("measure=interval_mean", "measure=entities"),
                PACK.replace("op=>", "op=!="),
                PACK.replace("clear=1000", "clear=2000"),
                PACK.replace("for=1", "for=0"),
                PACK.replace("action=mark", "action=downgrade"),
                PACK.replace("action=mark", "action=mark factor=2"),
                PACK + "rule slow scope=entity measure=age op=> limit=1 for=1 clear=0 action=alert\n",
                PACK + "rule bad!name scope=entity measure=age op=> limit=1 for=1 clear=0 action=alert\n",
                PACK.replace("min_samples=2", "min_samples=0"),
                PACK.replace("limit=1500", "limit=1e999"),
                PACK + "time_default s error_ms=-1\n",
                PACK + "time_default s state=late\n",
                PACK + "pack\tp\u0001\n",
                PACK.replace("window ", "# window ")))
            Check.throwsA(LoadError.class, () -> QualityPack.parse(bad), "load error: " + bad);
    }

    static Map<String, Object> report(String uid, long t) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("track.source_id", "s");
        r.put("uid", uid);
        r.put("time_ms", t);
        r.put("lat", 50.0);
        r.put("lon", 10.0);
        return r;
    }

    public static void testProcessor() throws LoadError {
        Quality q = Quality.fromText(PACK);
        Result first = q.ingest(report("1", 1000));
        Check.eq("new", first.events.get(0).get("ev"), "new");
        Check.eq("pass", first.events.get(1).get("ev"), "forwarded");
        q.ingest(report("1", 3000));
        q.ingest(report("1", 5000));
        Result tick = q.tick(5000);
        Check.eq("quality", tick.events.get(0).get("ev"), "entity measures");
        Check.eq("action-start", tick.events.get(1).get("ev"), "interval_mean 2000 > 1500: the rule starts");
        Result pass = q.ingest(report("1", 6000));
        Map<?, ?> fwd = (Map<?, ?>) pass.events.get(0).get("report");
        Check.eq(List.of("slow"), fwd.get("quality.marks"), "marked while active");
        Check.eq("tick-out-of-order", q.tick(4000).events.get(0).get("reason"), "a tick before the last");
    }
}
