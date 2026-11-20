package goat.fuse;

import goat.model.Axis;

/** fuse.md, Kinematics, {@code covariance_intersection}: the weight and the fold, pure. */
final class Kinematics {
    private Kinematics() {}

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
