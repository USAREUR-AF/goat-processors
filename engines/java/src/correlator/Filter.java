package correlator;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * An entity's estimate: correlate.md, Track estimate (one constant-velocity filter) and
 * Two-model filter (two such filters with shared mode probabilities).
 */
final class Filter {

    /** Track estimate: one axis of the constant-velocity filter, {@code [p, v, pp, pv, vv]}. */
    static final class Axis {
        double p, v, pp, pv, vv;

        Axis(double p, double v, double pp, double pv, double vv) {
            this.p = p; this.v = v; this.pp = pp; this.pv = pv; this.vv = vv;
        }

        Axis copy() {
            return new Axis(p, v, pp, pv, vv);
        }

        /** Step 1, predict over dt seconds with acceleration variance q. */
        void predict(double dt, double q) {
            double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
            p = p0 + v0 * dt;
            pp = pp0 + 2 * dt * pv0 + dt * dt * vv0 + q * dt * dt * dt * dt / 4;
            pv = pv0 + dt * vv0 + q * dt * dt * dt / 2;
            vv = vv0 + q * dt * dt;
        }

        /** Step 2, position update; returns the likelihood term {@code y*y/s + ln(s)} (Two-model filter step 3). */
        double updatePosition(double z, double r) {
            double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
            double s = pp0 + r, k1 = pp0 / s, k2 = pv0 / s, y = z - p0;
            p = p0 + k1 * y;
            v = v0 + k2 * y;
            pp = (1 - k1) * pp0;
            pv = (1 - k1) * pv0;
            vv = vv0 - k2 * pv0;
            return y * y / s + Math.log(s);
        }

        /** Step 3, velocity update; returns the likelihood term {@code y*y/s + ln(s)}. */
        double updateVelocity(double z, double r) {
            double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
            double s = vv0 + r, k1 = pv0 / s, k2 = vv0 / s, y = z - v0;
            p = p0 + k1 * y;
            v = v0 + k2 * y;
            pp = pp0 - k1 * pv0;
            pv = (1 - k2) * pv0;
            vv = (1 - k2) * vv0;
            return y * y / s + Math.log(s);
        }

        List<Object> toList() {
            return List.of(p, v, pp, pv, vv);
        }
    }

    /** The measurements of one report, in the plane. */
    static final class Measurement {
        final double[] z;      // east, north position
        final double r;        // ce²
        final boolean hasVel;
        final double[] zv;     // east, north velocity

        Measurement(double[] z, double ce, boolean hasVel, double ve, double vn) {
            this.z = z;
            this.r = ce * ce;
            this.hasVel = hasVel;
            this.zv = new double[] {ve, vn};
        }
    }

    /** Two-model filter, step 1: {@code blend(w1, w2)} of two states of one axis. */
    static Axis blend(double w1, Axis m1, double w2, Axis m2) {
        double p = w1 * m1.p + w2 * m2.p;
        double v = w1 * m1.v + w2 * m2.v;
        double d1 = m1.p - p, e1 = m1.v - v, d2 = m2.p - p, e2 = m2.v - v;
        double pp = w1 * (m1.pp + d1 * d1) + w2 * (m2.pp + d2 * d2);
        double pv = w1 * (m1.pv + d1 * e1) + w2 * (m2.pv + d2 * e2);
        double vv = w1 * (m1.vv + e1 * e1) + w2 * (m2.vv + e2 * e2);
        return new Axis(p, v, pp, pv, vv);
    }

    /** Model names of Two-model filter, index 0 is model 1. */
    static final String[] MODEL = {"quiet", "manoeuvre"};

    private final Pack pack;
    /** The entity's filter: the only one, or the combination of the two models. */
    Axis[] axes;
    /** With {@code manoeuvre}: models[j] is model j+1's {east, north}; mu[j] its mode probability. */
    Axis[][] models;
    double[] mu;

    /** Track estimate, first report (and Two-model filter, first report). */
    Filter(Pack pack, Measurement m) {
        this.pack = pack;
        double vv = m.hasVel ? pack.velSigma * pack.velSigma : pack.unknownVel * pack.unknownVel;
        axes = new Axis[2];
        for (int k = 0; k < 2; k++) axes[k] = new Axis(m.z[k], m.hasVel ? m.zv[k] : 0, m.r, 0, vv);
        if (pack.manoeuvre) {
            models = new Axis[][] {{axes[0].copy(), axes[1].copy()}, {axes[0].copy(), axes[1].copy()}};
            double s = pack.pEnter + pack.pLeave;
            mu = new double[] {pack.pLeave / s, pack.pEnter / s};
        }
    }

    Axis east() {
        return axes[0];
    }

    Axis north() {
        return axes[1];
    }

    /** Model j's acceleration variance (index 0 is {@code quiet}). */
    private double q(int j) {
        return j == 0 ? pack.accelVar : pack.manoeuvreAccelVar;
    }

    /**
     * A later report dt seconds after the last. Returns the Two-model filter trace values
     * {@code [lambda1, lambda2, mu1, mu2]}, or null with one filter.
     */
    double[] update(double dt, Measurement m) {
        if (!pack.manoeuvre) {
            for (int k = 0; k < 2; k++) predictAndUpdate(axes[k], k, dt, pack.accelVar, m);
            return null;
        }
        // Switching over dt seconds: t[i][j] is the probability of model j given model i.
        double a = pack.pEnter, b = pack.pLeave;
        double s = a + b;
        double l = Math.pow(1 - s, dt);
        double t12 = a / s * (1 - l);
        double t21 = b / s * (1 - l);
        double[][] t = {{1 - t12, t12}, {t21, 1 - t21}};

        // 1. Mixing, both mixed states from the model states before mixing.
        double[] c = new double[2];
        Axis[][] mixed = new Axis[2][];
        for (int j = 0; j < 2; j++) {
            c[j] = t[0][j] * mu[0] + t[1][j] * mu[1];
            if (c[j] == 0) {
                mixed[j] = new Axis[] {models[j][0].copy(), models[j][1].copy()};
                continue;
            }
            double w1 = t[0][j] * mu[0] / c[j], w2 = t[1][j] * mu[1] / c[j];
            mixed[j] = new Axis[] {blend(w1, models[0][0], w2, models[1][0]),
                    blend(w1, models[0][1], w2, models[1][1])};
        }

        // 2. Predict and update each model from its mixed state; 3. its log-likelihood.
        double[] lambda = new double[2];
        for (int j = 0; j < 2; j++) {
            Axis[] ax = mixed[j];
            for (int k = 0; k < 2; k++) ax[k].predict(dt, q(j));
            // Terms in the order east position, north position, east velocity, north velocity.
            double g = 0;
            for (int k = 0; k < 2; k++) g += ax[k].updatePosition(m.z[k], m.r);
            if (m.hasVel)
                for (int k = 0; k < 2; k++) g += ax[k].updateVelocity(m.zv[k], pack.velSigma * pack.velSigma);
            lambda[j] = -0.5 * g;
            models[j] = ax;
        }

        // 4. Mode probabilities; m is the larger lambda of the models with cj above 0.
        double mx = Double.NEGATIVE_INFINITY;
        for (int j = 0; j < 2; j++) if (c[j] > 0 && lambda[j] > mx) mx = lambda[j];
        double[] e = new double[2];
        for (int j = 0; j < 2; j++) e[j] = c[j] > 0 ? c[j] * Math.exp(lambda[j] - mx) : 0;
        double sum = e[0] + e[1];
        mu = new double[] {e[0] / sum, e[1] / sum};

        // 5. Combination.
        combine();
        return new double[] {lambda[0], lambda[1], mu[0], mu[1]};
    }

    /** Track estimate steps 1 to 3 on one axis k. */
    private void predictAndUpdate(Axis ax, int k, double dt, double q, Measurement m) {
        ax.predict(dt, q);
        ax.updatePosition(m.z[k], m.r);
        if (m.hasVel) ax.updateVelocity(m.zv[k], pack.velSigma * pack.velSigma);
    }

    private void combine() {
        for (int k = 0; k < 2; k++) axes[k] = blend(mu[0], models[0][k], mu[1], models[1][k]);
    }

    /**
     * Prediction to dt seconds after the last report, on copies: the filter predicted, or with two
     * models each model predicted with its own q and combined by the current mode probabilities.
     */
    Axis[] predicted(double dt) {
        Axis[] out = new Axis[2];
        for (int k = 0; k < 2; k++) {
            if (!pack.manoeuvre) {
                out[k] = axes[k].copy();
                out[k].predict(dt, pack.accelVar);
            } else {
                Axis m1 = models[0][k].copy(), m2 = models[1][k].copy();
                m1.predict(dt, q(0));
                m2.predict(dt, q(1));
                out[k] = blend(mu[0], m1, mu[1], m2);
            }
        }
        return out;
    }

    /** Snapshot: {@code filter}, and with two models {@code models} and {@code mode}. */
    void putSnapshot(Map<String, Object> entity) {
        entity.put("filter", axesMap(axes));
        if (!pack.manoeuvre) return;
        Map<String, Object> ms = new LinkedHashMap<>();
        for (int j = 0; j < 2; j++) ms.put(MODEL[j], axesMap(models[j]));
        entity.put("models", ms);
        entity.put("mode", new ArrayList<Object>(List.of(mu[0], mu[1])));
    }

    private static Map<String, Object> axesMap(Axis[] ax) {
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("east", ax[0].toList());
        f.put("north", ax[1].toList());
        return f;
    }
}
