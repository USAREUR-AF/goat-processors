package correlator;

import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Spec correlate.md, section Reports: the required keys, the optional-key rules
 * and the entity key. The correlator and the filter (filter.md, Reports) both
 * read reports this way.
 */
public final class Reports {
    private Reports() {}

    /** The required keys, in the order they are checked. */
    public static final String[] REQUIRED = {"track.source_id", "uid", "time_ms", "lat", "lon"};

    /** "Key order" is ascending byte order; UTF-8 byte order equals code point order. */
    public static final Comparator<String> KEY_ORDER = (x, y) -> Arrays.compare(
            x.codePoints().toArray(), y.codePoints().toArray());

    /**
     * The first required key that is missing (absent, null or of the wrong type),
     * or null when every required key is present. `track.source_id` and `uid` are
     * strings, `time_ms` an integer (a JSON number with no fraction or exponent,
     * which the JSON reader gives as Long), `lat` and `lon` numbers.
     */
    public static String missingKey(Map<String, Object> report) {
        for (String k : REQUIRED) {
            Object o = report.get(k);
            boolean ok = k.equals("time_ms") ? o instanceof Long
                    : k.equals("lat") || k.equals("lon") ? o instanceof Number
                    : o instanceof String;
            if (!ok) return k;
        }
        return null;
    }

    /** The entity key `<track.source_id>/<uid>` of a report whose required keys are present. */
    public static String entityKey(Map<String, Object> report) {
        return report.get("track.source_id") + "/" + report.get("uid");
    }

    /**
     * The report with the optional-key rules applied: a null value is the same as
     * the key being absent; `hae`, `ce`, `course`, `speed_ms` must be numbers,
     * `type` a string and `stale_ms` an integer, else they are absent; a `ce` of 0
     * or below is absent. Every key left in the result is present.
     */
    public static Map<String, Object> present(Map<String, Object> report) {
        Map<String, Object> m = new LinkedHashMap<>(report);
        m.values().removeIf(v -> v == null);
        for (String k : new String[] {"hae", "ce", "course", "speed_ms"})
            if (!(m.get(k) instanceof Number)) m.remove(k);
        if (m.containsKey("ce") && ((Number) m.get("ce")).doubleValue() <= 0) m.remove("ce");
        if (!(m.get("type") instanceof String)) m.remove("type");
        if (!(m.get("stale_ms") instanceof Long)) m.remove("stale_ms");
        return m;
    }
}
