package goat.correlate;

import goat.io.LoadError;
import goat.io.Processor;
import goat.model.Frame;
import goat.model.KeyOrder;
import goat.model.Measurement;
import goat.model.Report;
import goat.model.TrackEstimate;
import goat.trace.Records;
import goat.trace.Result;

import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * The correlator: load_pack, ingest, tick, snapshot (correlate.md 1.0, What the correlator does).
 * The report path every method shares (Reports, Frame, Track estimate, Measurement variance,
 * Restart) is here; the pack's {@code method} decides the rest.
 */
public final class Correlator implements Processor {

    final CorrelatePack pack;
    Double lat0, lon0;
    final TreeMap<String, Entity> entities = new TreeMap<>(KeyOrder.KEY_ORDER);
    /** correlate.md, Stale time of a source: with stale_rate, each source's last intervals, oldest first. */
    private final TreeMap<String, ArrayDeque<Long>> intervals = new TreeMap<>(KeyOrder.KEY_ORDER);
    private final Method method;

    public Correlator(CorrelatePack pack) {
        this.pack = pack;
        this.method = pack.registry.method(pack.method).factory.create(this, pack);
    }

    public static Correlator load(Path dir) throws LoadError {
        return new Correlator(CorrelatePack.load(dir));
    }

    public static Correlator fromText(String packDef) throws LoadError {
        return new Correlator(CorrelatePack.parse(packDef));
    }

    /** load_pack from pack.def text read against a registry of tests and methods. */
    public static Correlator fromText(String packDef, Registry registry) throws LoadError {
        return new Correlator(CorrelatePack.parse(packDef, registry));
    }

    /** The entities, in key order. */
    public TreeMap<String, Entity> entities() {
        return entities;
    }

    // ---- ingest (correlate.md: Reports, Track estimate, Association "On each accepted report") ----

    @Override
    public Result ingest(Map<String, Object> report) {
        Result res = new Result();
        String missing = Report.missingKey(report);
        if (missing != null) {
            res.events.add(Records.ev("reject", "reason", "missing:" + missing));
            return res;
        }
        String source = (String) report.get("track.source_id");
        String key = Report.entityKey(report);
        long time = ((Number) report.get("time_ms")).longValue();
        Entity a = entities.get(key);
        // correlate-assign.md, Window: after the required keys, before out-of-order.
        if (a != null && a.retiring) {
            res.events.add(Records.ev("reject", "entity", key, "reason", "retiring"));
            return res;
        }
        if (a != null && time < a.lastTime) {
            res.events.add(Records.ev("reject", "entity", key, "reason", "out-of-order"));
            return res;
        }

        double lat = ((Number) report.get("lat")).doubleValue();
        double lon = ((Number) report.get("lon")).doubleValue();
        if (lat0 == null) {
            lat0 = lat;
            lon0 = lon;
        }
        double[] en = Frame.toPlane(lat0, lon0, lat, lon);
        Object ceObj = report.get("ce");
        // Reports: a ce of 0 or below is treated as absent.
        boolean ceOk = ceObj instanceof Number && ((Number) ceObj).doubleValue() > 0;
        double ce = ceOk ? ((Number) ceObj).doubleValue() : pack.defaultCe;
        Object course = report.get("course"), speed = report.get("speed_ms");
        boolean hasVel = course instanceof Number && speed instanceof Number;
        double ve = 0, vn = 0;
        if (hasVel) {
            double sp = ((Number) speed).doubleValue(), c = Frame.rad(((Number) course).doubleValue());
            ve = sp * Math.sin(c);
            vn = sp * Math.cos(c);
        }

        // Track estimate, Measurement variance, with te the report's time error (Reports, Time quality).
        // The time state is found as well; correlate does not use it in this version.
        double te = Report.timeError(report, pack.timeDefault);
        Report.timeState(report, pack.timeDefault);
        double[] r = new double[2], timingVar = new double[2];
        if (te == 0) {
            r[0] = ce * ce;
            r[1] = ce * ce;
        } else {
            // The velocity: the entity's prediction to time_ms, or for a first report the measured
            // velocity, or 0 without one.
            double[] vel;
            if (a == null) vel = new double[] {ve, vn};
            else {
                Predicted pr = Predicted.of(a, time);
                vel = new double[] {pr.east.v, pr.north.v};
            }
            double ts = te / 1000;
            for (int k = 0; k < 2; k++) {
                double moved = vel[k] * ts;
                timingVar[k] = moved * moved;
                r[k] = ce * ce + timingVar[k];
            }
            res.trace.add(timeRec(key, te, timingVar));
        }

        Measurement meas = new Measurement(en, r, hasVel, ve, vn);
        // Stale time of a source: an accepted report of an entity that already existed appends
        // its interval to its source's list, which keeps the last `samples`.
        if (a != null && pack.staleRate) {
            ArrayDeque<Long> list = intervals.computeIfAbsent(source, k -> new ArrayDeque<>());
            list.addLast(time - a.lastTime);
            while (list.size() > pack.staleSamples) list.removeFirst();
        }
        if (a == null) {
            // Track estimate (and Two-model filter), first report: no trace record.
            a = new Entity(key, source);
            a.filter = TrackEstimate.first(pack.filter, meas);
            entities.put(key, a);
            res.events.add(Records.ev("new", "entity", key));
        } else if (pack.restart && !restartPasses(a, time, meas, res)) {
            // Restart: the filter starts again from this report as a first report. No `new` event;
            // the entity keeps its key, group, pair counts and hold failure count.
            a.filter = TrackEstimate.first(pack.filter, meas);
            method.restarted(key);
        } else {
            // Later reports; with two models, the four filter records come before any association record.
            TrackEstimate.Updated u = a.filter.update((time - a.lastTime) / 1000.0, meas);
            a.filter = u.estimate;
            double[] f = u.trace;
            if (f != null) {
                res.trace.add(filterRec(a, TrackEstimate.MODEL[0], "likelihood", f[0]));
                res.trace.add(filterRec(a, TrackEstimate.MODEL[1], "likelihood", f[1]));
                res.trace.add(filterRec(a, TrackEstimate.MODEL[0], "mode", f[2]));
                res.trace.add(filterRec(a, TrackEstimate.MODEL[1], "mode", f[3]));
            }
        }
        a.lastTime = time;
        // Reports, the optional-key rules.
        a.last = Report.present(report);
        a.ce = ce;
        // Track estimate, Measurement variance: the entity keeps this report's r and timing
        // variance (also after a restart).
        a.timeError = te;
        a.r = r;
        a.timingVar = timingVar;

        method.reported(a, res);
        return res;
    }

    /**
     * correlate.md, Restart: d² of the report against the entity predicted to its time_ms, and its
     * trace record, before any other record of the report. True when d² is below the gate.
     */
    private boolean restartPasses(Entity a, long time, Measurement meas, Result res) {
        // Not a comparison with another entity: no timing variance on the prediction.
        Predicted pr = Predicted.of(a, time);
        double de = meas.z[0] - pr.east.p, dn = meas.z[1] - pr.north.p;
        double d2 = de * de / (pr.east.pp + meas.r[0]) + dn * dn / (pr.north.pp + meas.r[1]);
        boolean pass = d2 < pack.restartGate;
        res.trace.add(Records.test("filter", a.key, null, "restart", d2, pack.restartGate, pass));
        return pass;
    }

    /** Runs the tests of one stage for A against B, with the method's frame move. */
    public boolean runTests(java.util.List<CorrelatePack.Test> tests, String stage, Entity a, Entity b, Result res) {
        return Tests.run(tests, stage, a, b, method.frameMove(), res);
    }

    // ---- tick and snapshot: the method's ----

    @Override
    public Result tick(long now) {
        return method.tick(now);
    }

    @Override
    public Map<String, Object> snapshot() {
        return method.snapshot();
    }

    // ---- helpers ----

    /** The frame reference {@code [lat0, lon0]}, or null before the first report. */
    public Object ref() {
        return goat.snapshot.Snapshots.ref(lat0, lon0);
    }

    /** correlate.md, Frame, back to degrees. */
    public double[] toDegrees(double east, double north) {
        return Frame.toDegrees(lat0, lon0, east, north);
    }

    /** correlate.md, Association, On each tick, Staleness: the rule both methods use. */
    public boolean isStale(Entity e, long now) {
        Object st = e.last.get("stale_ms");
        return now - e.lastTime > staleTime(e.source) || (st instanceof Long && now >= (Long) st);
    }

    /**
     * correlate.md, Stale time of a source: {@code stale_ms}, or with {@code stale_rate}
     * {@code k * m}, m the lower median of the source's intervals, within [floor, ceiling];
     * the ceiling with no interval.
     */
    public double staleTime(String source) {
        if (!pack.staleRate) return pack.staleMs;
        ArrayDeque<Long> list = intervals.get(source);
        if (list == null || list.isEmpty()) return pack.staleCeiling;
        return staleTime(pack.staleFactor, pack.staleFloor, pack.staleCeiling, list);
    }

    /** The stale time of one source's intervals: k times their lower median, within [floor, ceiling]. A pure function. */
    public static double staleTime(double factor, long floor, long ceiling, java.util.Collection<Long> list) {
        long[] sorted = new long[list.size()];
        int i = 0;
        for (long v : list) sorted[i++] = v;
        Arrays.sort(sorted);
        double st = factor * sorted[(sorted.length - 1) / 2];
        if (st < floor) st = floor;
        if (st > ceiling) st = ceiling;
        return st;
    }

    /** Snapshot, with stale_rate: {@code intervals}, each source with at least one, oldest first. */
    public void putIntervals(Map<String, Object> s) {
        if (!pack.staleRate) return;
        Map<String, Object> m = new LinkedHashMap<>();
        for (Map.Entry<String, ArrayDeque<Long>> e : intervals.entrySet()) {
            if (e.getValue().isEmpty()) continue;
            List<Object> l = new ArrayList<>(e.getValue());
            m.put(e.getKey(), l);
        }
        s.put("intervals", m);
    }

    /** Track estimate, Measurement variance: the {@code time} record of a report with time error above 0. */
    private static Map<String, Object> timeRec(String key, double te, double[] timingVar) {
        Map<String, Object> m = Records.test("filter", key, null, "time", te, null, true);
        m.put("var_east", timingVar[0]);
        m.put("var_north", timingVar[1]);
        return m;
    }

    /** Two-model filter, Trace: one filter record. */
    private static Map<String, Object> filterRec(Entity a, String model, String test, double value) {
        return Records.test("filter", a.key, model, test, value, null, true);
    }
}
