package goat.fuse;

import goat.model.Axis;
import goat.model.InverseVariance;
import goat.trace.Records;
import goat.trace.Result;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * fuse.md, Kinematics: the table of methods, by the name of the pack's {@code kinematics} line. A
 * new method is one entry. Each combines a group's members (predicted to the tick, in key order)
 * into the fused estimate, and names the member it came from when it is one member's.
 */
final class Kinematics {
    private Kinematics() {}

    /** The fused estimate {east, north}, and the member it is, or null for a combination. */
    static final class Estimate {
        final Axis[] fused;
        final Fuse.Member from;

        Estimate(Axis[] fused, Fuse.Member from) {
            this.fused = fused;
            this.from = from;
        }

        static Estimate of(Fuse.Member m) {
            return new Estimate(new Axis[] {m.east, m.north}, m);
        }
    }

    /**
     * The table, in the order of fuse.md, Kinematics: one constant per method (an enum, so the
     * table costs no start-up work). A new method is one more constant.
     */
    enum Method {
        INVERSE_VARIANCE("inverse_variance") {
            @Override
            Estimate combine(Fuse.Group g, List<Fuse.Member> members, Fuse fuse, Result res) {
                return new Estimate(inverseVariance(members), null);
            }
        },
        COVARIANCE_INTERSECTION("covariance_intersection") {
            @Override
            Estimate combine(Fuse.Group g, List<Fuse.Member> members, Fuse fuse, Result res) {
                return new Estimate(covarianceIntersection(g, members, res), null);
            }
        },
        BEST("best") {
            @Override
            boolean better(Fuse.Member m, Fuse.Member win, Fuse fuse) {
                return m.var() < win.var();
            }
        },
        PRIORITY("priority") {
            @Override
            boolean better(Fuse.Member m, Fuse.Member win, Fuse fuse) {
                return fuse.rankOrder(m.e) < fuse.rankOrder(win.e);
            }
        },
        LATEST("latest") {
            @Override
            boolean better(Fuse.Member m, Fuse.Member win, Fuse fuse) {
                return m.e.lastTime > win.e.lastTime;
            }
        };

        /** The name on the pack's {@code kinematics} line. */
        final String name;

        Method(String name) {
            this.name = name;
        }

        /**
         * The fused estimate of a group. By default the one member whose filter is the estimate
         * ({@code best}, {@code priority}, {@code latest}): the first that no later member beats.
         */
        Estimate combine(Fuse.Group g, List<Fuse.Member> members, Fuse fuse, Result res) {
            Fuse.Member win = null;
            for (Fuse.Member m : members) if (win == null || better(m, win, fuse)) win = m;
            return Estimate.of(win);
        }

        /** True when m beats the current winner; members come in key order, so ties keep the earlier. */
        boolean better(Fuse.Member m, Fuse.Member win, Fuse fuse) {
            throw new IllegalStateException(name + " is not a pick");
        }
    }

    /** The table by name, in the order of fuse.md. */
    static final Map<String, Method> TABLE = table();

    private static Map<String, Method> table() {
        Map<String, Method> t = new LinkedHashMap<>();
        for (Method m : Method.values()) t.put(m.name, m);
        return Collections.unmodifiableMap(t);
    }

    /** {@code inverse_variance}: correlate-assign.md's fused estimate, members in key order. */
    static Axis[] inverseVariance(List<Fuse.Member> members) {
        List<Axis[]> predicted = new ArrayList<>();
        for (Fuse.Member m : members) predicted.add(new Axis[] {m.east, m.north});
        return InverseVariance.combine(predicted);
    }

    /** {@code covariance_intersection}: fold the members in key order; one trace record per fold. */
    static Axis[] covarianceIntersection(Fuse.Group g, List<Fuse.Member> members, Result res) {
        Fuse.Member first = members.get(0);
        Axis xe = first.east, xn = first.north;
        for (Fuse.Member y : members.subList(1, members.size())) {
            double w = intersectionWeight(xe.pp, xn.pp, y.east.pp, y.north.pp);
            res.trace.add(Records.rec("stage", "intersect", "group", g.name, "member", y.e.key, "value", w));
            if (w == 1) continue; // X unchanged
            if (w == 0) {         // Y unchanged
                xe = y.east;
                xn = y.north;
                continue;
            }
            xe = fold(w, xe, y.east);
            xn = fold(w, xn, y.north);
        }
        return new Axis[] {xe, xn};
    }

    /** Covariance intersection, Weight: the closed form, steps 1 to 5 in order. */
    static double intersectionWeight(double xppe, double xppn, double yppe, double yppn) {
        double ae = 1 / yppe, an = 1 / yppn;            // 1
        double de = 1 / xppe - ae, dn = 1 / xppn - an;  // 2
        double c2 = de * dn;                            // 3
        double c1 = ae * dn + an * de;                  // 4
        double w;                                       // 5
        if (c2 < 0) {
            w = -c1 / (2 * c2);
            if (w < 0) w = 0;
            if (w > 1) w = 1;
        } else if (c1 + c2 > 0) {
            w = 1;
        } else if (c1 + c2 < 0) {
            w = 0;
        } else {
            w = 0.5;
        }
        return w;
    }

    /** Covariance intersection, Fold, one axis; pv of the result is unused and 0. */
    static Axis fold(double w, Axis x, Axis y) {
        double a = w / x.pp, b = (1 - w) / y.pp, pp = 1 / (a + b);
        double p = pp * (a * x.p + b * y.p);
        double c = w / x.vv, d = (1 - w) / y.vv, vv = 1 / (c + d);
        double v = vv * (c * x.v + d * y.v);
        return new Axis(p, v, pp, 0, vv);
    }
}
