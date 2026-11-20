package goat.assign;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import goat.correlate.CorrelatePack;
import goat.correlate.Entity;
import goat.correlate.FrameMove;
import goat.correlate.Predicted;
import goat.model.Axis;
import goat.model.KeyOrder;

/**
 * correlate-assign.md, Sensor bias: one position offset per unordered pair of sources, the
 * move of a predicted entity into another source's frame, and the update at each tick.
 */
final class Bias implements FrameMove {

    /**
     * State of one pair {@code "<S>|<T>"}: per axis the offset o and weight sum w, one var, the
     * count n; with {@code time_offset} also the clock offset tau (seconds) and the sums S1 to S8
     * ({@code sums[0]} is S1).
     */
    static final class PairState {
        final double[] o = new double[2];
        final double[] w = new double[2];
        double var;
        long n;
        double tau;
        final double[] sums = new double[8];

        PairState(double sigma) {
            var = sigma * sigma;
        }
    }

    private final CorrelatePack pack;
    /** The stored pairs, by pair key in key order. */
    private final TreeMap<String, PairState> pairs = new TreeMap<>(KeyOrder.KEY_ORDER);

    Bias(CorrelatePack pack) {
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
     * a_src is first; pp + var either way. With {@code time_offset}, o - v*tau is used in place of
     * o, v B's predicted velocity on that axis. Two entities of one source are never moved.
     */
    @Override
    public void moveInto(String aSource, String bSource, Axis[] predictedB) {
        int c = KeyOrder.KEY_ORDER.compare(bSource, aSource);
        if (c == 0) return;
        PairState st = c < 0 ? read(bSource, aSource) : read(aSource, bSource);
        double sign = c < 0 ? 1 : -1;
        for (int k = 0; k < 2; k++) {
            double offset = pack.timeOffset ? st.o[k] - predictedB[k].v * st.tau : st.o[k];
            predictedB[k].p = predictedB[k].p + sign * offset;
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
        boolean xFirst = KeyOrder.KEY_ORDER.compare(x.source, y.source) < 0;
        Entity es = xFirst ? x : y, et = xFirst ? y : x;
        Predicted ps = new Predicted(es, now), pt = new Predicted(et, now);
        Axis[] axS = {ps.east, ps.north}, axT = {pt.east, pt.north};
        String key = es.source + "|" + et.source;
        PairState st = read(es.source, et.source);
        double[] yy = new double[2], r = new double[2], v = new double[2];
        for (int k = 0; k < 2; k++) {
            yy[k] = axT[k].p - axS[k].p;
            r[k] = axS[k].pp + axT[k].pp;
            // Time offset: the object's velocity, v = (v_ES + v_ET) / 2.
            v[k] = (axS[k].v + axT[k].v) / 2;
        }
        // 2. d² = sum over east, north of (y - o)² / (var + r), with the pair's state; with
        //    time_offset, (y - (o - v*tau))².
        double d2 = 0;
        for (int k = 0; k < 2; k++) {
            double d = pack.timeOffset ? yy[k] - (st.o[k] - v[k] * st.tau) : yy[k] - st.o[k];
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
            if (pack.timeOffset) fitTimeOffset(st, r, v, yy);
            else {
                for (int k = 0; k < 2; k++) {
                    double wBefore = st.w[k], oBefore = st.o[k];
                    st.w[k] = wBefore + 1 / r[k];
                    st.o[k] = oBefore + ((1 / r[k]) / st.w[k]) * (yy[k] - oBefore);
                }
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
        if (pack.timeOffset) m.put("time_offset_ms", st.tau * 1000);
        trace.add(m);
    }

    /**
     * Time offset, an accepted pair: the sums S1 to S8 (each += one addition of the whole
     * right-hand side), then the weighted least-squares fit of y = o - v*tau over every accepted
     * pair, with priors of 0 for o (standard deviation s) and tau (standard deviation t ms), in
     * the closed form as written. The weight sum w of each axis is S1 and S2.
     */
    private void fitTimeOffset(PairState st, double[] r, double[] v, double[] y) {
        double[] S = st.sums;
        double we = 1 / r[0], wn = 1 / r[1];
        double ve = v[0], vn = v[1], ye = y[0], yn = y[1];
        S[0] = S[0] + we;
        S[1] = S[1] + wn;
        S[2] = S[2] + we * ve;
        S[3] = S[3] + wn * vn;
        S[4] = S[4] + (we * ve * ve + wn * vn * vn);
        S[5] = S[5] + we * ye;
        S[6] = S[6] + wn * yn;
        S[7] = S[7] + (we * ve * ye + wn * vn * yn);
        double s = pack.biasSigma, t = pack.timeOffsetSigmaMs;
        double po = 1 / (s * s);
        double tSeconds = t / 1000;
        double pt = 1 / (tSeconds * tSeconds);
        double a11 = po + S[0], a22 = po + S[1];
        double a13 = -S[2], a23 = -S[3];
        double a33 = pt + S[4];
        double b1 = S[5], b2 = S[6], b3 = -S[7];
        st.tau = (b3 - a13 * b1 / a11 - a23 * b2 / a22) / (a33 - a13 * a13 / a11 - a23 * a23 / a22);
        st.o[0] = (b1 - a13 * st.tau) / a11;
        st.o[1] = (b2 - a23 * st.tau) / a22;
        st.w[0] = S[0];
        st.w[1] = S[1];
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
            if (pack.timeOffset) {
                m.put("time_offset_ms", st.tau * 1000);
                List<Object> sums = new ArrayList<>();
                for (double x : st.sums) sums.add(x);
                m.put("sums", sums);
            }
            out.put(p.getKey(), m);
        }
        return out;
    }
}
