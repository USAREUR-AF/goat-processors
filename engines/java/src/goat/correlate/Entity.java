package goat.correlate;

import goat.model.TrackEstimate;

import java.util.LinkedHashMap;
import java.util.Map;

/** One correlate entity: its filter, its last report, and what each method keeps for it. */
public final class Entity {
    public final String key, source;
    public long lastTime;
    public TrackEstimate filter;
    /** The last report with the optional-key rules applied (correlate.md, Reports). */
    public Map<String, Object> last;
    public double ce;
    /** Track estimate, Measurement variance: the last report's time error (ms), r and timing variance, east and north. */
    public double timeError;
    public double[] r = new double[2];
    public double[] timingVar = new double[2];
    /** Method confirm: the entity's group and hold failure count. */
    public String group;
    public long holdFailures;
    /** Method assign: the entity's system track in the committed membership. */
    public String system;
    /** Method assign: found stale, its drop not yet committed (correlate-assign.md, Window step 1). */
    public boolean retiring;

    Entity(String key, String source) {
        this.key = key;
        this.source = source;
    }

    /** Snapshot: {@code time}, the timing variance, when the last report had a time error above 0. */
    public void putTimeSnapshot(Map<String, Object> m) {
        if (!(timeError > 0)) return;
        Map<String, Object> t = new LinkedHashMap<>();
        t.put("var_east", timingVar[0]);
        t.put("var_north", timingVar[1]);
        m.put("time", t);
    }

    /** A number-valued key of the last report, or null. */
    public Double num(String k) {
        Object o = last.get(k);
        return o instanceof Number ? ((Number) o).doubleValue() : null;
    }
}
