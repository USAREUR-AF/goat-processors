package goat.model;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * An entity's estimate: correlate.md, Track estimate (one constant-velocity filter) and
 * Two-model filter (two such filters with shared mode probabilities). A value: {@link #update}
 * returns the next estimate.
 */
public final class TrackEstimate {

    /** Model names of Two-model filter, index 0 is model 1. */
    public static final String[] MODEL = {"quiet", "maneuver"};

    private final FilterParams fp;
    /** The entity's filter: the only one, or the combination of the two models; {east, north}. */
    private final Axis[] axes;
    /** With {@code maneuver}: models[j] is model j+1's {east, north}; mu[j] its mode probability. */
    private final Axis[][] models;
    private final double[] mu;

    private TrackEstimate(FilterParams fp, Axis[] axes, Axis[][] models, double[] mu) {
        this.fp = fp;
        this.axes = axes;
        this.models = models;
        this.mu = mu;
    }

    /** Track estimate, first report (and Two-model filter, first report): pp is that axis's r. */
    public static TrackEstimate first(FilterParams fp, Measurement m) {
        double vv = m.hasVel ? fp.velSigma * fp.velSigma : fp.unknownVel * fp.unknownVel;
        Axis[] axes = new Axis[2];
        for (int k = 0; k < 2; k++) axes[k] = new Axis(m.z[k], m.hasVel ? m.zv[k] : 0, m.r[k], 0, vv);
        if (!fp.maneuver) return new TrackEstimate(fp, axes, null, null);
        double s = fp.pEnter + fp.pLeave;
        return new TrackEstimate(fp, axes, new Axis[][] {axes.clone(), axes.clone()},
                new double[] {fp.pLeave / s, fp.pEnter / s});
    }

    public Axis east() {
        return axes[0];
    }

    public Axis north() {
        return axes[1];
    }

    /** The next estimate after a later report, and the Two-model filter trace values. */
    public static final class Updated {
        public final TrackEstimate estimate;
        /** {@code [lambda1, lambda2, mu1, mu2]}, or null with one filter. */
        public final double[] trace;

        Updated(TrackEstimate estimate, double[] trace) {
            this.estimate = estimate;
            this.trace = trace;
        }
    }

    /** Track estimate, Later reports, steps 1 to 3 on one axis: predict, then update. */
    public static Axis predictAndUpdate(Axis ax, double dt, double q, double z, double r, boolean hasVel,
                                        double zv, double rv) {
        Axis out = ax.predict(dt, q).updatePosition(z, r);
        return hasVel ? out.updateVelocity(zv, rv) : out;
    }

    /** A later report dt seconds after the last. */
    public Updated update(double dt, Measurement m) {
        double rv = fp.velSigma * fp.velSigma;
        if (!fp.maneuver) {
            Axis[] next = new Axis[2];
            for (int k = 0; k < 2; k++)
                next[k] = predictAndUpdate(axes[k], dt, fp.accelVar, m.z[k], m.r[k], m.hasVel, m.zv[k], rv);
            return new Updated(new TrackEstimate(fp, next, null, null), null);
        }
        double[][] t = switching(fp.pEnter, fp.pLeave, dt);

        // 1. Mixing, both mixed states from the model states before mixing.
        double[] c = new double[2];
        Axis[][] mixed = new Axis[2][];
        for (int j = 0; j < 2; j++) {
            c[j] = t[0][j] * mu[0] + t[1][j] * mu[1];
            if (c[j] == 0) {
                mixed[j] = models[j];
                continue;
            }
            double w1 = t[0][j] * mu[0] / c[j], w2 = t[1][j] * mu[1] / c[j];
            mixed[j] = new Axis[] {blend(w1, models[0][0], w2, models[1][0]),
                    blend(w1, models[0][1], w2, models[1][1])};
        }

        // 2. Predict and update each model from its mixed state; 3. its log-likelihood.
        double[] lambda = new double[2];
        Axis[][] nextModels = new Axis[2][];
        for (int j = 0; j < 2; j++) {
            Axis[] ax = new Axis[2];
            for (int k = 0; k < 2; k++) ax[k] = mixed[j][k].predict(dt, q(j));
            // Terms in the order east position, north position, east velocity, north velocity.
            double g = 0;
            for (int k = 0; k < 2; k++) {
                g += ax[k].positionTerm(m.z[k], m.r[k]);
                ax[k] = ax[k].updatePosition(m.z[k], m.r[k]);
            }
            if (m.hasVel)
                for (int k = 0; k < 2; k++) {
                    g += ax[k].velocityTerm(m.zv[k], rv);
                    ax[k] = ax[k].updateVelocity(m.zv[k], rv);
                }
            lambda[j] = -0.5 * g;
            nextModels[j] = ax;
        }

        // 4. Mode probabilities; 5. combination.
        double[] nextMu = modeProbabilities(c, lambda);
        Axis[] next = new Axis[2];
        for (int k = 0; k < 2; k++) next[k] = blend(nextMu[0], nextModels[0][k], nextMu[1], nextModels[1][k]);
        return new Updated(new TrackEstimate(fp, next, nextModels, nextMu),
                new double[] {lambda[0], lambda[1], nextMu[0], nextMu[1]});
    }

    /** Two-model filter, switching over dt seconds: t[i][j] is the probability of model j given model i. */
    public static double[][] switching(double pEnter, double pLeave, double dt) {
        double a = pEnter, b = pLeave;
        double s = a + b;
        double l = Math.pow(1 - s, dt);
        double t12 = a / s * (1 - l);
        double t21 = b / s * (1 - l);
        return new double[][] {{1 - t12, t12}, {t21, 1 - t21}};
    }

    /** Two-model filter, step 4: m is the larger lambda of the models with cj above 0. */
    public static double[] modeProbabilities(double[] c, double[] lambda) {
        double mx = Double.NEGATIVE_INFINITY;
        for (int j = 0; j < 2; j++) if (c[j] > 0 && lambda[j] > mx) mx = lambda[j];
        double[] e = new double[2];
        for (int j = 0; j < 2; j++) e[j] = c[j] > 0 ? c[j] * Math.exp(lambda[j] - mx) : 0;
        double sum = e[0] + e[1];
        return new double[] {e[0] / sum, e[1] / sum};
    }

    /** Two-model filter, step 1: {@code blend(w1, w2)} of two states of one axis. */
    public static Axis blend(double w1, Axis m1, double w2, Axis m2) {
        double p = w1 * m1.p + w2 * m2.p;
        double v = w1 * m1.v + w2 * m2.v;
        double d1 = m1.p - p, e1 = m1.v - v, d2 = m2.p - p, e2 = m2.v - v;
        double pp = w1 * (m1.pp + d1 * d1) + w2 * (m2.pp + d2 * d2);
        double pv = w1 * (m1.pv + d1 * e1) + w2 * (m2.pv + d2 * e2);
        double vv = w1 * (m1.vv + e1 * e1) + w2 * (m2.vv + e2 * e2);
        return new Axis(p, v, pp, pv, vv);
    }

    /** Model j's acceleration variance (index 0 is {@code quiet}). */
    private double q(int j) {
        return j == 0 ? fp.accelVar : fp.maneuverAccelVar;
    }

    /**
     * Prediction to dt seconds after the last report: the filter predicted, or with two models
     * each model predicted with its own q and combined by the current mode probabilities.
     */
    public Axis[] predicted(double dt) {
        Axis[] out = new Axis[2];
        for (int k = 0; k < 2; k++) {
            out[k] = !fp.maneuver ? axes[k].predict(dt, fp.accelVar)
                    : blend(mu[0], models[0][k].predict(dt, q(0)), mu[1], models[1][k].predict(dt, q(1)));
        }
        return out;
    }

    /** Snapshot: {@code filter}, and with two models {@code models} and {@code mode}. */
    public void putSnapshot(Map<String, Object> entity) {
        entity.put("filter", axesMap(axes));
        if (!fp.maneuver) return;
        Map<String, Object> ms = new LinkedHashMap<>();
        for (int j = 0; j < 2; j++) ms.put(MODEL[j], axesMap(models[j]));
        entity.put("models", ms);
        entity.put("mode", new ArrayList<Object>(List.of(mu[0], mu[1])));
    }

    /** Snapshot: {@code {"east": [...], "north": [...]}}. */
    public static Map<String, Object> axesMap(Axis[] ax) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("east", ax[0].toList());
        f.put("north", ax[1].toList());
        return f;
    }

    /** Snapshot: {@code {"east": [...], "north": [...]}}. */
    public static Map<String, Object> axesMap(Axis east, Axis north) {
        return axesMap(new Axis[] {east, north});
    }
}
