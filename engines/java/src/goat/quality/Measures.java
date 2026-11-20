package goat.quality;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** quality.md, Entity measures and Source measures: pure functions of a window and of entity measures. */
final class Measures {
    private Measures() {}

    /**
     * Spec: Entity measures, over an entity's window W at a tick: last is the entity's latest
     * accepted time and k the pack's min_samples.
     */
    static Map<String, Object> entityMeasures(List<Record> w, long last, long now, long k) {
        List<Long> intervals = new ArrayList<>(), latencies = new ArrayList<>(), stateCodes = new ArrayList<>();
        List<Number> lateness = new ArrayList<>();
        List<Double> nis = new ArrayList<>(), speedErr = new ArrayList<>(), timeErrors = new ArrayList<>();
        long outOfOrder = 0, duplicate = 0, sourceOutOfOrder = 0, noCe = 0, noVel = 0, noHae = 0, noTime = 0;
        for (Record rec : w) {
            if (rec.interval != null) intervals.add(rec.interval);
            if (rec.latency != null) latencies.add(rec.latency);
            if (rec.lateness != null) lateness.add(rec.lateness);
            if (rec.nis != null) nis.add(rec.nis);
            if (rec.speedErr != null) speedErr.add(rec.speedErr);
            if (rec.timeError != null) timeErrors.add(rec.timeError);
            if (rec.timeState != null) stateCodes.add(stateCode(rec.timeState));
            else noTime++;
            if (rec.order.equals("out-of-order")) outOfOrder++;
            if (rec.order.equals("duplicate")) duplicate++;
            if (rec.sourceOutOfOrder) sourceOutOfOrder++;
            if (!rec.ce) noCe++;
            if (!rec.vel) noVel++;
            if (!rec.hae) noHae++;
        }
        long reports = w.size();
        boolean enoughIntervals = intervals.size() >= k, enoughLatencies = latencies.size() >= k;
        boolean enoughLateness = lateness.size() >= k, enoughErrors = timeErrors.size() >= k;
        boolean enoughStates = stateCodes.size() >= k, enoughReports = reports >= k;

        Map<String, Object> m = new LinkedHashMap<>();
        m.put("reports", reports);
        m.put("interval_last", enoughIntervals ? intervals.get(intervals.size() - 1) : null);
        m.put("interval_mean", enoughIntervals ? mean(intervals) : null);
        m.put("interval_max", enoughIntervals ? max(intervals) : null);
        m.put("age", now - last);
        m.put("latency_mean", enoughLatencies ? mean(latencies) : null);
        m.put("latency_max", enoughLatencies ? max(latencies) : null);
        m.put("lateness_mean", enoughLateness ? mean(lateness) : null);
        m.put("lateness_max", enoughLateness ? max(lateness) : null);
        m.put("lateness_min", enoughLateness ? min(lateness) : null);
        m.put("nis_mean", nis.size() >= k ? mean(nis) : null);
        m.put("speed_err_mean", speedErr.size() >= k ? mean(speedErr) : null);
        m.put("out_of_order", outOfOrder);
        m.put("duplicate", duplicate);
        m.put("source_out_of_order", sourceOutOfOrder);
        m.put("missing_ce", enoughReports ? (double) noCe / reports : null);
        m.put("missing_vel", enoughReports ? (double) noVel / reports : null);
        m.put("missing_hae", enoughReports ? (double) noHae / reports : null);
        m.put("time_error_mean", enoughErrors ? mean(timeErrors) : null);
        m.put("time_error_max", enoughErrors ? max(timeErrors) : null);
        m.put("time_state_last", enoughStates ? stateCodes.get(stateCodes.size() - 1) : null);
        m.put("time_state_worst", enoughStates ? max(stateCodes) : null);
        m.put("missing_time", enoughReports ? (double) noTime / reports : null);
        return m;
    }

    /** Spec: Source measures, aggregating its entities' measures (given in key order). */
    static Map<String, Object> sourceMeasures(List<Map<String, Object>> members) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (String name : QualityPack.ENTITY_MEASURES) {
            List<Number> present = new ArrayList<>();
            for (Map<String, Object> em : members) if (em.get(name) != null) present.add((Number) em.get(name));
            switch (name) {
                case "reports": case "out_of_order": case "duplicate": case "source_out_of_order": {
                    long s = 0;
                    for (Number x : present) s += x.longValue();
                    m.put(name, s);
                    break;
                }
                case "interval_max": case "latency_max": case "lateness_max": case "time_error_max":
                case "time_state_last": case "time_state_worst":
                    m.put(name, present.isEmpty() ? null : max(present));
                    break;
                case "lateness_min":
                    m.put(name, present.isEmpty() ? null : min(present));
                    break;
                case "age": {
                    long min = Long.MAX_VALUE;
                    for (Number x : present) min = Math.min(min, x.longValue());
                    m.put(name, min);
                    break;
                }
                default:
                    m.put(name, present.isEmpty() ? null : mean(present));
            }
        }
        m.put("entities", (long) members.size());
        return m;
    }

    /** Spec: Entity measures, a mean is s / n with s summed from 0.0 in order, in binary64. */
    static double mean(List<? extends Number> xs) {
        double s = 0.0;
        for (Number x : xs) s += x.doubleValue();
        return s / xs.size();
    }

    /**
     * The largest of a non-empty list, kept as given (an integer sample stays an integer).
     * Two integers compare exactly; any other pair compares as binary64.
     */
    static Number max(List<? extends Number> xs) {
        Number best = xs.get(0);
        for (Number x : xs) if (compare(x, best) > 0) best = x;
        return best;
    }

    /** The smallest of a non-empty list, as {@link #max}. */
    static Number min(List<? extends Number> xs) {
        Number best = xs.get(0);
        for (Number x : xs) if (compare(x, best) < 0) best = x;
        return best;
    }

    static int compare(Number x, Number y) {
        if (x instanceof Long && y instanceof Long) return Long.compare((Long) x, (Long) y);
        return Double.compare(x.doubleValue(), y.doubleValue());
    }

    /** Spec: Reports, Time quality: the code of a time state (higher is worse). */
    static long stateCode(String state) {
        switch (state) {
            case "coherent": return 0;
            case "drifting": return 1;
            default: return 2; // free-running
        }
    }
}
