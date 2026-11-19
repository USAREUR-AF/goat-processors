package correlator;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import correlator.Engine.Entity;

/**
 * correlate-assign.md, Sensor bias: one position offset per unordered pair of sources, the
 * move of a predicted entity into another source's frame, and the update at each tick.
 */
final class Bias {

    /** State of one pair {@code "<S>|<T>"}: per axis the offset o and weight sum w, one var, the count n. */
    static final class PairState {
        final double[] o = new double[2];
        final double[] w = new double[2];
        double var;
        long n;

        PairState(double sigma) {
            var = sigma * sigma;
        }
    }

    private final Pack pack;
    /** The stored pairs, by pair key in key order. */
    private final TreeMap<String, PairState> pairs = new TreeMap<>(Engine.KEY_ORDER);

    Bias(Pack pack) {
        this.pack = pack;
    }

    /** A pair with no stored state reads as o = 0, w = 0, var = s², n = 0. */
    private PairState read(String first, String second) {
        PairState st = pairs.get(first + "|" + second);
        return st != null ? st : new PairState(pack.biasSigma);
    }

    /**
     * Moving B into A's frame: B's prediction (east, north; copies the caller owns) becomes
     * p + o from pair "b_src|a_src" when b_src is first, or p - o from pair "a_src|b_src" when
     * a_src is first; pp + var either way. Two entities of one source are never moved.
     */
    void moveInto(String aSource, String bSource, Filter.Axis[] predictedB) {
        int c = Engine.KEY_ORDER.compare(bSource, aSource);
        if (c == 0) return;
        PairState st = c < 0 ? read(bSource, aSource) : read(aSource, bSource);
        double sign = c < 0 ? 1 : -1;
        for (int k = 0; k < 2; k++) {
            predictedB[k].p = predictedB[k].p + sign * st.o[k];
            predictedB[k].pp = predictedB[k].pp + st.var;
        }
    }

    /**
     * Update, at each tick after the commit: every committed system track in creation order, its
     * members that are not retiring in key order, each pair X before Y from two sources with at
     * least one of them among the tick's rows.
     */
    void update(Map<String, TreeSet<String>> committedSystems, Map<String, Entity> entities,
                TreeSet<String> rows, long now, List<Map<String, Object>> trace) {
        for (TreeSet<String> keys : committedSystems.values()) {
            List<Entity> members = new ArrayList<>();
            for (String k : keys) {
                Entity e = entities.get(k);
                if (!e.retiring) members.add(e);
            }
            for (int i = 0; i < members.size(); i++) {
                for (int j = i + 1; j < members.size(); j++) {
                    Entity x = members.get(i), y = members.get(j);
                    if (x.source.equals(y.source)) continue;
                    if (!rows.contains(x.key) && !rows.contains(y.key)) continue;
                    updatePair(x, y, now, trace);
                }
            }
        }
    }

    private void updatePair(Entity x, Entity y, long now, List<Map<String, Object>> trace) {
        // 1. ES is the entity whose source is first in key order, ET the other; both predicted to
        //    now, not moved. Per axis y = p_ET - p_ES and r = pp_ES + pp_ET.
        boolean xFirst = Engine.KEY_ORDER.compare(x.source, y.source) < 0;
        Entity es = xFirst ? x : y, et = xFirst ? y : x;
        Engine.Predicted ps = new Engine.Predicted(es, now), pt = new Engine.Predicted(et, now);
        Filter.Axis[] axS = {ps.east, ps.north}, axT = {pt.east, pt.north};
        String key = es.source + "|" + et.source;
        PairState st = read(es.source, et.source);
        double[] yy = new double[2], r = new double[2];
        for (int k = 0; k < 2; k++) {
            yy[k] = axT[k].p - axS[k].p;
            r[k] = axS[k].pp + axT[k].pp;
        }
        // 2. d² = sum over east, north of (y - o)² / (var + r), with the pair's state.
        double d2 = 0;
        for (int k = 0; k < 2; k++) {
            double d = yy[k] - st.o[k];
            d2 += d * d / (st.var + r[k]);
        }
        // 3. Accepted when d² < g: n + 1; var = s² / (n + 1), no less than f²; per axis the
        //    weighted mean with weight 1/r. The state is stored.
        boolean accepted = d2 < pack.biasGate;
        if (accepted) {
            st.n = st.n + 1;
            double s2 = pack.biasSigma * pack.biasSigma, f2 = pack.biasFloor * pack.biasFloor;
            double var = s2 / (st.n + 1);
            st.var = var < f2 ? f2 : var;
            for (int k = 0; k < 2; k++) {
                double wBefore = st.w[k], oBefore = st.o[k];
                st.w[k] = wBefore + 1 / r[k];
                st.o[k] = oBefore + ((1 / r[k]) / st.w[k]) * (yy[k] - oBefore);
            }
            pairs.put(key, st);
        }
        // 4. Trace, with the state after step 3.
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("stage", "bias");
        m.put("a", x.key);
        m.put("b", y.key);
        m.put("test", "offset");
        m.put("value", d2);
        m.put("limit", pack.biasGate);
        m.put("pass", accepted);
        m.put("east", st.o[0]);
        m.put("north", st.o[1]);
        m.put("var", st.var);
        m.put("pairs", st.n);
        trace.add(m);
    }

    /** Snapshot: each stored pair key, in key order, to its state. */
    Map<String, Object> snapshot() {
        Map<String, Object> out = new LinkedHashMap<>();
        for (Map.Entry<String, PairState> p : pairs.entrySet()) {
            PairState st = p.getValue();
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("east", st.o[0]);
            m.put("weight_east", st.w[0]);
            m.put("north", st.o[1]);
            m.put("weight_north", st.w[1]);
            m.put("var", st.var);
            m.put("pairs", st.n);
            out.put(p.getKey(), m);
        }
        return out;
    }
}
