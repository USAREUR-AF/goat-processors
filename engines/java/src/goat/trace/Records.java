package goat.trace;

import java.util.LinkedHashMap;
import java.util.Map;

/** Builders of events and trace records: JSON objects with their keys in the order given. */
public final class Records {
    private Records() {}

    /** An event {@code {"ev": name, k1: v1, ...}}. */
    public static Map<String, Object> ev(String name, Object... kv) {
        Map<String, Object> m = new Fields();
        m.put("ev", name);
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
        return m;
    }

    /** An object {@code {k1: v1, ...}}. */
    public static Map<String, Object> rec(Object... kv) {
        Map<String, Object> m = new Fields();
        for (int k = 0; k < kv.length; k += 2) m.put((String) kv[k], kv[k + 1]);
        return m;
    }

    /**
     * The correlate trace record of spec correlate.md, Trace: stage, a, b, test, value, limit,
     * pass, in that order.
     */
    public static Map<String, Object> test(String stage, Object a, Object b, String test, Object value,
                                           Object limit, boolean pass) {
        Map<String, Object> m = new Fields();
        m.put("stage", stage);
        m.put("a", a);
        m.put("b", b);
        m.put("test", test);
        m.put("value", value);
        m.put("limit", limit);
        m.put("pass", pass);
        return m;
    }
}
