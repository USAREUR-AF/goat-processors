package goat.fuse;

import goat.io.LoadError;
import goat.model.Axis;
import goat.testkit.Check;
import goat.trace.Result;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Unit tests of the fuse module: the pack, the kinematics table, the weight and fold, the processor. */
public final class FuseTest {
    private FuseTest() {}

    static final String PACK = "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
            + "kinematics best\nattribute track.confidence rule=max\nattribute type rule=majority\nsource radar\nsource beacon\n"
            + "stale_ms 60000\n";

    public static void testPack() throws LoadError {
        FusePack p = FusePack.parse(PACK);
        Check.eq("best", p.kinematics, "kinematics");
        Check.eq(List.of("radar", "beacon"), p.sources, "sources in rank order");
        Check.eq(2, p.attributes.size(), "attributes");
        Check.eq(60000L, p.staleMs, "stale_ms");
        Check.eq(List.of("inverse_variance", "covariance_intersection", "best", "priority", "latest"), FusePack.METHODS,
                "the kinematics table, in spec order");
    }

    public static void testPackErrors() {
        for (String bad : List.of(
                PACK.replace("kinematics best", "kinematics mean"),
                PACK.replace("rule=max", "rule=sum"),
                PACK + "attribute type rule=max\n",
                PACK + "source radar\n",
                PACK.replace("stale_ms 60000", "stale_ms -1"),
                PACK.replace("default_ce_m=50 ", ""),
                PACK.replace("accel_var=1", "accel_var=x"),
                PACK.replace("vel_sigma_ms=5", "vel_sigma_ms=0"),
                PACK + "attribute a=b rule=max\n",
                PACK + "bogus\n",
                PACK.replace("version 1\n", "")))
            Check.throwsA(LoadError.class, () -> FusePack.parse(bad), "load error: " + bad);
    }

    public static void testIntersectionWeight() {
        Check.same(1, Kinematics.intersectionWeight(1, 1, 4, 4), "X better on both axes: X");
        Check.same(0, Kinematics.intersectionWeight(4, 4, 1, 1), "Y better on both axes: Y");
        Check.same(0.5, Kinematics.intersectionWeight(2, 2, 2, 2), "equal: one half");
        double w = Kinematics.intersectionWeight(1, 4, 4, 1);
        Check.isTrue(w > 0 && w < 1, "crossed: between, " + w);
        Check.same(0.5, w, "symmetric crossing: one half");
    }

    public static void testFold() {
        Axis x = new Axis(0, 0, 2, 9, 2), y = new Axis(10, 4, 2, 9, 2);
        Axis f = Kinematics.fold(0.5, x, y);
        Check.eq(List.of(5.0, 2.0, 2.0, 0.0, 2.0), f.toList(), "half and half: the mean, pv 0");
    }

    static Map<String, Object> report(String src, String uid, long t, String group) {
        Map<String, Object> r = new LinkedHashMap<>();
        r.put("track.source_id", src);
        r.put("uid", uid);
        r.put("time_ms", t);
        r.put("lat", 50.0);
        r.put("lon", 10.0);
        if (group != null) r.put("fuse.group", group);
        return r;
    }

    public static void testProcessor() throws LoadError {
        Fuse f = Fuse.fromText(PACK);
        Result r = f.ingest(report("radar", "1", 1000, "obj"));
        Check.eq(Map.of("ev", "new", "entity", "radar/1", "group", "obj"), r.events.get(0), "new");
        Result older = f.ingest(report("radar", "1", 999, "obj"));
        Check.eq("stale-report", older.events.get(0).get("ev"), "older report ignored");
        Result moved = f.ingest(report("radar", "1", 1000, ""));
        Check.eq("move", moved.events.get(0).get("ev"), "an empty group is no group: a move");
        Check.eq(null, moved.events.get(0).get("to"), "to no group");
        f.ingest(report("beacon", "2", 1000, null));
        Result tick = f.tick(2000);
        Check.eq(2, tick.events.size(), "two unnamed groups");
        Check.eq("beacon/2", tick.events.get(0).get("from"), "unnamed groups in key order; best of one member is that member");
        Result late = f.tick(62000);
        Check.eq("drop", late.events.get(0).get("ev"), "stale");
    }

    public static void testNormalize() {
        Map<String, Object> r = report("radar", "1", 1000, null);
        r.put("fuse.group", 5L);
        r.put("ce", -1L);
        Map<String, Object> n = Fuse.normalize(r);
        Check.isTrue(!n.containsKey("fuse.group") && !n.containsKey("ce"), "an unusable group and ce are absent");
    }

    public static void testCompareAndMajority() {
        Check.eq(-1, Fuse.compare(9007199254740992L, 9007199254740993L), "two integers exactly");
        Check.eq(0, Fuse.compare(9007199254740992L, 9007199254740993.0), "otherwise as binary64");
        Check.isTrue(Fuse.majorityEqual(1L, 1.0), "numbers by value");
        Check.isTrue(!Fuse.majorityEqual("1", 1L), "a string is not a number");
        Check.isTrue(Fuse.majorityEqual(true, true), "booleans");
    }
}
