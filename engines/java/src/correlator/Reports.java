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

    /**
     * Time quality (correlate.md, Reports, "Time quality"): the report's {@code time_error_ms}
     * when present, a number, finite and 0 or above; otherwise the pack's {@code time_default}
     * {@code error_ms} for the report's source; otherwise 0, the exact time of every version
     * before 0.8. A value of the wrong type, negative or not finite is absent, never a reject.
     */
    public static double timeError(Map<String, Object> report, Map<String, Map<String, Object>> defaults) {
        Double own = reportTimeError(report);
        if (own != null) return own;
        Map<String, Object> d = defaults.get((String) report.get("track.source_id"));
        if (d != null && d.containsKey("error_ms")) return (Double) d.get("error_ms");
        return 0;
    }

    /**
     * The report's time state, found per key as {@link #timeError}: its {@code time_state} when it
     * is one of {@code coherent}, {@code drifting}, {@code free-running} (byte for byte), else the
     * pack's {@code time_default} state for its source, else {@code coherent}. Correlate parses
     * and validates it but does not use it in this version.
     */
    public static String timeState(Map<String, Object> report, Map<String, Map<String, Object>> defaults) {
        String own = reportTimeState(report);
        if (own != null) return own;
        Map<String, Object> d = defaults.get((String) report.get("track.source_id"));
        if (d != null && d.containsKey("state")) return (String) d.get("state");
        return "coherent";
    }

    /**
     * Time quality, step 1: the report's own {@code time_error_ms} when it is valid (a number,
     * finite and 0 or above), else null. Quality (quality.md, Reports, "Time quality") reads the
     * key the same way.
     */
    public static Double reportTimeError(Map<String, Object> report) {
        Object o = report.get("time_error_ms");
        if (!(o instanceof Number)) return null;
        double te = ((Number) o).doubleValue();
        return Double.isFinite(te) && te >= 0 ? te : null;
    }

    /**
     * Time quality, step 1: the report's own {@code time_state} when it is one of the three
     * states (byte for byte), else null. Quality reads the key the same way.
     */
    public static String reportTimeState(Map<String, Object> report) {
        Object o = report.get("time_state");
        return o instanceof String && Pack.TIME_STATES.contains(o) ? (String) o : null;
    }
}
