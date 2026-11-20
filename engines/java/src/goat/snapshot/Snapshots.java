package goat.snapshot;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Pieces every function's snapshot shares. */
public final class Snapshots {
    private Snapshots() {}

    /** {@code ref}: the frame reference {@code [lat0, lon0]}, or null before the first report. */
    public static Object ref(Double lat0, Double lon0) {
        return lat0 == null ? null : List.of(lat0, lon0);
    }

    /** A JSON array of the values, in iteration order. */
    public static List<Object> list(Collection<?> values) {
        return new ArrayList<Object>(values);
    }

    /** A JSON object of named lists (system or group name to members), in iteration order. */
    public static <C extends Collection<String>> Map<String, Object> lists(Map<String, C> named) {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<String, C> e : named.entrySet()) out.put(e.getKey(), list(e.getValue()));
        return out;
    }
}
