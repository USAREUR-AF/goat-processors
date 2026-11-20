package goat.trace;

import goat.snapshot.Snapshots;
import goat.testkit.Check;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/** Unit tests of the trace and snapshot modules. */
public final class TraceTest {
    private TraceTest() {}

    public static void testEventKeyOrder() {
        Map<String, Object> e = Records.ev("leave", "group", "g1", "entity", "a/1", "reason", "hold");
        Check.eq(List.of("ev", "group", "entity", "reason"), List.copyOf(e.keySet()), "keys in the order given");
        Check.eq("leave", e.get("ev"), "name");
    }

    public static void testRecord() {
        Map<String, Object> r = Records.rec("x", 1L, "y", null);
        Check.eq(Arrays.asList("x", "y"), List.copyOf(r.keySet()), "keys");
        Check.isTrue(r.containsKey("y") && r.get("y") == null, "null kept as a key");
    }

    public static void testTestRecord() {
        Map<String, Object> r = Records.test("gate", "a", "b", "distance", 3.0, 5.0, true);
        Check.eq(List.of("stage", "a", "b", "test", "value", "limit", "pass"), List.copyOf(r.keySet()), "correlate.md Trace keys");
    }

    public static void testResultStartsEmpty() {
        Result r = new Result();
        Check.isTrue(r.events.isEmpty() && r.trace.isEmpty(), "empty");
    }

    public static void testSnapshotPieces() {
        Check.eq(null, Snapshots.ref(null, null), "no reference yet");
        Check.eq(List.of(1.0, 2.0), Snapshots.ref(1.0, 2.0), "reference");
        Map<String, TreeSet<String>> named = new LinkedHashMap<>();
        named.put("s2", new TreeSet<>(List.of("b", "a")));
        named.put("s1", new TreeSet<>(List.of("c")));
        Map<String, Object> m = Snapshots.lists(named);
        Check.eq(List.of("s2", "s1"), List.copyOf(m.keySet()), "names in iteration order");
        Check.eq(List.of("a", "b"), m.get("s2"), "members as a list");
    }
}
