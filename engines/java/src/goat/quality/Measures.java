package goat.quality;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * quality.md, Entity measures and Source measures: the table of measures, and the pure functions
 * that compute them. A table is immutable; {@link #STANDARD} is the specification's, and
 * {@link #with} gives a table with one more measure. A new measure is one entry: its name, its
 * value over an entity's window ({@link Window}), and how a source aggregates it.
 */
public final class Measures {

    /** How a source measure aggregates its entities' values of one measure (quality.md, Source measures). */
    public enum Aggregate {
        /** The sum of the present values, an integer; 0 with none. */
        SUM,
        /** The largest present value, kept as given; null with none. */
        MAX,
        /** The smallest present value, kept as given; null with none. */
        MIN,
        /** The smallest value as an integer (every entity has one). */
        LEAST,
        /** The mean of the present values; null with none. */
        MEAN
    }

    /** One measure: its name, its entity value (null when not enough samples), its source aggregate. */
    public static final class Measure {
        public interface Value {
            Object of(Window w);
        }

        public final String name;
        public final Value value;
        public final Aggregate aggregate;

        public Measure(String name, Value value, Aggregate aggregate) {
            this.name = name;
            this.value = value;
            this.aggregate = aggregate;
        }
    }

    /**
     * The samples of one entity's window W at a tick, gathered once in arrival order; {@code k} is
     * the pack's min_samples, {@code last} the entity's latest accepted time.
     */
    public static final class Window {
        public final List<Record> records;
        public final long last, now, k;
        final List<Long> intervals = new ArrayList<>(), latencies = new ArrayList<>(), stateCodes = new ArrayList<>();
        final List<Number> lateness = new ArrayList<>();
        final List<Double> nis = new ArrayList<>(), speedErr = new ArrayList<>(), timeErrors = new ArrayList<>();
        long outOfOrder, duplicate, sourceOutOfOrder, noCe, noVel, noHae, noTime;

        public Window(List<Record> records, long last, long now, long k) {
            this.records = records;
            this.last = last;
            this.now = now;
            this.k = k;
            for (Record rec : records) {
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
        }

        /** At least k samples. */
        public boolean enough(List<?> samples) {
            return samples.size() >= k;
        }

        public long reports() {
            return records.size();
        }

        /** A fraction of the reports, with at least k reports. */
        Double fraction(long count) {
            return reports() >= k ? (Double) ((double) count / reports()) : null;
        }
    }

    /** quality.md, Entity measures: the table, in table order (the order of the measures object). */
    public static final Measures STANDARD = new Measures(List.of(
            new Measure("reports", w -> w.reports(), Aggregate.SUM),
            new Measure("interval_last", w -> w.enough(w.intervals) ? w.intervals.get(w.intervals.size() - 1) : null,
                    Aggregate.MEAN),
            new Measure("interval_mean", w -> w.enough(w.intervals) ? mean(w.intervals) : null, Aggregate.MEAN),
            new Measure("interval_max", w -> w.enough(w.intervals) ? max(w.intervals) : null, Aggregate.MAX),
            new Measure("age", w -> w.now - w.last, Aggregate.LEAST),
            new Measure("latency_mean", w -> w.enough(w.latencies) ? mean(w.latencies) : null, Aggregate.MEAN),
            new Measure("latency_max", w -> w.enough(w.latencies) ? max(w.latencies) : null, Aggregate.MAX),
            new Measure("lateness_mean", w -> w.enough(w.lateness) ? mean(w.lateness) : null, Aggregate.MEAN),
            new Measure("lateness_max", w -> w.enough(w.lateness) ? max(w.lateness) : null, Aggregate.MAX),
            new Measure("lateness_min", w -> w.enough(w.lateness) ? min(w.lateness) : null, Aggregate.MIN),
            new Measure("nis_mean", w -> w.enough(w.nis) ? mean(w.nis) : null, Aggregate.MEAN),
            new Measure("speed_err_mean", w -> w.enough(w.speedErr) ? mean(w.speedErr) : null, Aggregate.MEAN),
            new Measure("out_of_order", w -> w.outOfOrder, Aggregate.SUM),
            new Measure("duplicate", w -> w.duplicate, Aggregate.SUM),
            new Measure("source_out_of_order", w -> w.sourceOutOfOrder, Aggregate.SUM),
            new Measure("missing_ce", w -> w.fraction(w.noCe), Aggregate.MEAN),
            new Measure("missing_vel", w -> w.fraction(w.noVel), Aggregate.MEAN),
            new Measure("missing_hae", w -> w.fraction(w.noHae), Aggregate.MEAN),
            new Measure("time_error_mean", w -> w.enough(w.timeErrors) ? mean(w.timeErrors) : null, Aggregate.MEAN),
            new Measure("time_error_max", w -> w.enough(w.timeErrors) ? max(w.timeErrors) : null, Aggregate.MAX),
            new Measure("time_state_last",
                    w -> w.enough(w.stateCodes) ? w.stateCodes.get(w.stateCodes.size() - 1) : null, Aggregate.MAX),
            new Measure("time_state_worst", w -> w.enough(w.stateCodes) ? max(w.stateCodes) : null, Aggregate.MAX),
            new Measure("missing_time", w -> w.fraction(w.noTime), Aggregate.MEAN)));

    /** The source-only measure: the number of the source's entities. */
    public static final String ENTITIES = "entities";

    private final List<Measure> table;

    private Measures(List<Measure> table) {
        this.table = List.copyOf(table);
    }

    /** This table with one more measure, after the others. */
    public Measures with(Measure m) {
        List<Measure> t = new ArrayList<>(table);
        t.add(m);
        return new Measures(t);
    }

    /** The entity measures' names, in table order. */
    public List<String> entityNames() {
        List<String> out = new ArrayList<>();
        for (Measure m : table) out.add(m.name);
        return Collections.unmodifiableList(out);
    }

    /** The source measures' names: the entity measures, then {@code entities}. */
    public List<String> sourceNames() {
        List<String> out = new ArrayList<>(entityNames());
        out.add(ENTITIES);
        return Collections.unmodifiableList(out);
    }

    /** Entity measures over a window, in table order. */
    public Map<String, Object> entity(Window w) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (Measure x : table) m.put(x.name, x.value.of(w));
        return m;
    }

    /** Source measures, aggregating its entities' measures (given in key order). */
    public Map<String, Object> source(List<Map<String, Object>> members) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (Measure x : table) {
            List<Number> present = new ArrayList<>();
            for (Map<String, Object> em : members) if (em.get(x.name) != null) present.add((Number) em.get(x.name));
            m.put(x.name, aggregate(x.aggregate, present));
        }
        m.put(ENTITIES, (long) members.size());
        return m;
    }

    /** One source aggregate of the present values. */
    static Object aggregate(Aggregate a, List<Number> present) {
        switch (a) {
            case SUM: {
                long s = 0;
                for (Number x : present) s += x.longValue();
                return s;
            }
            case MAX:
                return present.isEmpty() ? null : max(present);
            case MIN:
                return present.isEmpty() ? null : min(present);
            case LEAST: {
                long min = Long.MAX_VALUE;
                for (Number x : present) min = Math.min(min, x.longValue());
                return min;
            }
            default:
                return present.isEmpty() ? null : (Double) mean(present);
        }
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
