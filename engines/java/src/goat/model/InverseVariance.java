package goat.model;

import java.util.List;

/**
 * correlate-assign.md, fused estimate: the inverse-variance combination of filters already
 * predicted to one time ({east, north} each, in the order given). Fuse's
 * {@code inverse_variance} kinematics is this same estimate (fuse.md, Kinematics).
 */
public final class InverseVariance {
    private InverseVariance() {}

    /** pv of the result is unused and 0. */
    public static Axis[] combine(List<Axis[]> predicted) {
        double[] invPP = new double[2], sumP = new double[2], invVV = new double[2], sumV = new double[2];
        for (Axis[] axes : predicted) {
            for (int k = 0; k < 2; k++) {
                invPP[k] += 1 / axes[k].pp;
                sumP[k] += axes[k].p / axes[k].pp;
                invVV[k] += 1 / axes[k].vv;
                sumV[k] += axes[k].v / axes[k].vv;
            }
        }
        Axis[] out = new Axis[2];
        for (int k = 0; k < 2; k++) {
            double pp = 1 / invPP[k], vv = 1 / invVV[k];
            out[k] = new Axis(pp * sumP[k], vv * sumV[k], pp, 0, vv);
        }
        return out;
    }
}
