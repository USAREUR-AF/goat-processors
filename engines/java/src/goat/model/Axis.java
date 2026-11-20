package goat.model;

import java.util.List;

/**
 * correlate.md, Track estimate: one axis of the constant-velocity filter, {@code [p, v, pp, pv, vv]}.
 * A value: every step returns a new axis and leaves this one as it was.
 */
public final class Axis {
    public final double p, v, pp, pv, vv;

    public Axis(double p, double v, double pp, double pv, double vv) {
        this.p = p; this.v = v; this.pp = pp; this.pv = pv; this.vv = vv;
    }

    /** Step 1, predict over dt seconds with acceleration variance q. */
    public Axis predict(double dt, double q) {
        return new Axis(p + v * dt,
                v,
                pp + 2 * dt * pv + dt * dt * vv + q * dt * dt * dt * dt / 4,
                pv + dt * vv + q * dt * dt * dt / 2,
                vv + q * dt * dt);
    }

    /** Step 2, position update with measurement z and variance r. */
    public Axis updatePosition(double z, double r) {
        double s = pp + r, k1 = pp / s, k2 = pv / s, y = z - p;
        return new Axis(p + k1 * y, v + k2 * y, (1 - k1) * pp, (1 - k1) * pv, vv - k2 * pv);
    }

    /** Step 3, velocity update with measurement z and variance r. */
    public Axis updateVelocity(double z, double r) {
        double s = vv + r, k1 = pv / s, k2 = vv / s, y = z - v;
        return new Axis(p + k1 * y, v + k2 * y, pp - k1 * pv, (1 - k2) * pv, (1 - k2) * vv);
    }

    /** Two-model filter, step 3: the position update's likelihood term {@code y*y/s + ln(s)}. */
    public double positionTerm(double z, double r) {
        double s = pp + r, y = z - p;
        return y * y / s + Math.log(s);
    }

    /** Two-model filter, step 3: the velocity update's likelihood term {@code y*y/s + ln(s)}. */
    public double velocityTerm(double z, double r) {
        double s = vv + r, y = z - v;
        return y * y / s + Math.log(s);
    }

    /** This axis with pp increased by x. */
    public Axis plusPp(double x) {
        return new Axis(p, v, pp + x, pv, vv);
    }

    /** This axis with p and pp replaced. */
    public Axis withP(double newP, double newPp) {
        return new Axis(newP, v, newPp, pv, vv);
    }

    /** Snapshot form {@code [p, v, pp, pv, vv]}. */
    public List<Object> toList() {
        return List.of(p, v, pp, pv, vv);
    }
}
