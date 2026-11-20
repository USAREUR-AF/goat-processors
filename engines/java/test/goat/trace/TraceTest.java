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

    /** Fields behaves as a LinkedHashMap: order, put again, remove, iterator, entries, equality. */
    public static void testFieldsIsAnOrderedMap() {
        Fields f = new Fields(1);
        java.util.LinkedHashMap<String, Object> l = new java.util.LinkedHashMap<>();
        goat.testkit.Rng r = new goat.testkit.Rng(5);
        for (int i = 0; i < 4000; i++) {
            String k = "k" + r.below(40);
            switch (r.below(4)) {
                case 0: case 1: Check.eq(l.put(k, (long) i), f.put(k, (long) i), "put " + k); break;
                case 2: Check.eq(l.remove(k), f.remove(k), "remove " + k); break;
                default: Check.eq(l.get(k), f.get(k), "get " + k);
            }
            Check.eq(List.copyOf(l.keySet()), List.copyOf(f.keySet()), "order");
            Check.eq(l.containsKey(k), f.containsKey(k), "containsKey");
        }
        Check.isTrue(f.equals(l) && l.equals(f) && f.hashCode() == l.hashCode(), "equal maps");
        Check.isTrue(!f.containsKey(7L) && f.get(7L) == null && f.remove(7L) == null, "a key that is not a string");
        java.util.Iterator<Map.Entry<String, Object>> it = f.entrySet().iterator();
        Map.Entry<String, Object> first = it.next();
        Check.eq(first.getValue(), first.setValue("x"), "setValue returns the old value");
        Check.eq("x", f.get(first.getKey()), "setValue writes through");
        Check.isTrue(first.equals(Map.entry(first.getKey(), "x")) && !first.equals("x"), "entry equality");
        Check.eq(Map.entry(first.getKey(), "x").hashCode(), first.hashCode(), "entry hash");
        it.remove();
        Check.isTrue(!f.containsKey(first.getKey()), "iterator remove");
        Check.throwsA(IllegalStateException.class, it::remove, "remove twice");
        while (it.hasNext()) it.next();
        Check.throwsA(java.util.NoSuchElementException.class, it::next, "past the end");
        Check.throwsA(NullPointerException.class, () -> f.put(null, 1L), "null key");
        f.clear();
        Check.eq(0, f.size(), "cleared");
        f.put("a", 1L);
        Check.eq(Map.of("a", 1L), f, "usable after clear");
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
