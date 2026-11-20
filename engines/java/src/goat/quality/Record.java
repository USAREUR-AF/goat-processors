package goat.quality;

import goat.trace.Fields;
import java.util.LinkedHashMap;
import java.util.Map;

/** Spec: Samples, one report's record. Samples are null when not taken. */
final class Record {
    long wt, timeMs;
    String order;
    Long interval, latency;
    /** A Long when the input clock is an integer, a Double when it is a mean of two. */
    Number lateness;
    Double nis, speedErr, timeError;
    String timeState;
    boolean sourceOutOfOrder;
    boolean ce, vel, hae;

    /** The time state's code (quality.md, Time quality), found once; not part of the snapshot. */
    private Long stateCode;

    Long stateCode() {
        if (stateCode == null && timeState != null) stateCode = Measures.stateCode(timeState);
        return stateCode;
    }

    Map<String, Object> toMap() {
        Map<String, Object> m = new Fields();
        m.put("wt", wt);
        m.put("time_ms", timeMs);
        m.put("order", order);
        m.put("interval", interval);
        m.put("latency", latency);
        m.put("lateness", lateness);
        m.put("source_out_of_order", sourceOutOfOrder);
        m.put("time_error", timeError);
        m.put("time_state", timeState);
        m.put("nis", nis);
        m.put("speed_err", speedErr);
        m.put("ce", ce);
        m.put("vel", vel);
        m.put("hae", hae);
        return m;
    }
}
