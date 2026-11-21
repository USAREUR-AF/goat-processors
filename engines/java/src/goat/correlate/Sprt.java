package goat.correlate;

import goat.io.LoadError;
import goat.model.Axis;

import java.util.HashSet;
import java.util.List;
import java.util.Map;

/**
 * correlate.md, Association, Sequential test: Wald's sequential probability ratio test on a
 * pair, its bounds, one report's evidence, and the {@code sprt} line. Pure; the pairs' {@code L}
 * live in {@link Confirm}.
 */
public final class Sprt {
    private Sprt() {}

    private static final List<String> PARAMS = List.of("false", "missed", "pos_m", "vel_ms", "hae_sigma_m");

    /** The {@code sprt} line: false and missed above 0 and below 0.5; pos_m, vel_ms, hae_sigma_m above 0. */
    static void line(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        Map<String, String> kv = CorrelatePack.params(tok, 1, ln);
        if (!kv.keySet().equals(new HashSet<>(PARAMS))) throw CorrelatePack.err(ln, "sprt takes " + PARAMS);
        pk.sprt = true;
        pk.sprtFalse = probability(CorrelatePack.dec(kv.get("false"), ln), "false", ln);
        pk.sprtMissed = probability(CorrelatePack.dec(kv.get("missed"), ln), "missed", ln);
        pk.sprtPos = CorrelatePack.positive(CorrelatePack.dec(kv.get("pos_m"), ln), "pos_m", ln);
        pk.sprtVel = CorrelatePack.positive(CorrelatePack.dec(kv.get("vel_ms"), ln), "vel_ms", ln);
        pk.sprtHaeSigma = CorrelatePack.positive(CorrelatePack.dec(kv.get("hae_sigma_m"), ln), "hae_sigma_m", ln);
    }

    private static double probability(double v, String name, int ln) throws LoadError {
        if (!(v > 0 && v < 0.5)) throw CorrelatePack.err(ln, name + " must be above 0 and below 0.5");
        return v;
    }

    /** {@code up = ln((1 - missed) / false)}. */
    public static double up(CorrelatePack pk) {
        return Math.log((1 - pk.sprtMissed) / pk.sprtFalse);
    }

    /** {@code lo = ln(missed / (1 - false))}. */
    public static double lo(CorrelatePack pk) {
        return Math.log(pk.sprtMissed / (1 - pk.sprtFalse));
    }

    /**
     * One report's evidence for A against B predicted (with B's timing variance) to A's time:
     * {@code {increment, d2}}.
     */
    public static double[] evidence(CorrelatePack pk, Entity a, Entity b, Predicted pb) {
        double bigP = pk.sprtPos * pk.sprtPos, bigV = pk.sprtVel * pk.sprtVel;
        double[] e = axis(a.filter.east(), a.timingVar[0], pb.east, bigP, bigV);
        double[] n = axis(a.filter.north(), a.timingVar[1], pb.north, bigP, bigV);
        double inc = e[0] + n[0];
        double d2 = e[1] + n[1];
        if (Tests.bothHae(a, b)) {
            double hs = pk.sprtHaeSigma;
            double h1 = 2 * hs * hs, h0 = h1 + bigP;
            double dh = a.num("hae") - b.num("hae");
            inc = inc + (0.5 * (dh * dh / h0 - dh * dh / h1) + 0.5 * Math.log(h0 / h1));
            d2 = d2 + dh * dh / h1;
        }
        return new double[] {inc, d2};
    }

    /** One axis: {@code {0.5*(q0 - q) + 0.5*ln(det0/det), q}}. */
    static double[] axis(Axis fa, double ta, Axis fb, double bigP, double bigV) {
        double[] s = Tests.stateAxis(fa, ta, fb);
        double dp = s[0], dv = s[1], spp = s[2], spv = s[3], svv = s[4], det = s[5], q = s[6];
        double tpp = spp + bigP, tvv = svv + bigV;
        double det0 = tpp * tvv - spv * spv;
        double q0 = (tvv * dp * dp - 2 * spv * dp * dv + tpp * dv * dv) / det0;
        return new double[] {0.5 * (q0 - q) + 0.5 * Math.log(det0 / det), q};
    }

    /** {@code L = min(max(L + increment, lo), up)}. */
    public static double update(double l, double inc, double lo, double up) {
        return Math.min(Math.max(l + inc, lo), up);
    }
}
