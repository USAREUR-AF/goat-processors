package goat.model;

import java.util.List;

/** correlate.md, Track estimate: one axis of the constant-velocity filter, {@code [p, v, pp, pv, vv]}. */
public final class Axis {
    public double p, v, pp, pv, vv;

    public Axis(double p, double v, double pp, double pv, double vv) {
        this.p = p; this.v = v; this.pp = pp; this.pv = pv; this.vv = vv;
    }

    public Axis copy() {
        return new Axis(p, v, pp, pv, vv);
    }

    /** Step 1, predict over dt seconds with acceleration variance q. */
    public void predict(double dt, double q) {
        double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
        p = p0 + v0 * dt;
        pp = pp0 + 2 * dt * pv0 + dt * dt * vv0 + q * dt * dt * dt * dt / 4;
        pv = pv0 + dt * vv0 + q * dt * dt * dt / 2;
        vv = vv0 + q * dt * dt;
    }

    /** Step 2, position update; returns the likelihood term {@code y*y/s + ln(s)} (Two-model filter step 3). */
    public double updatePosition(double z, double r) {
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
    public double updateVelocity(double z, double r) {
        double p0 = p, v0 = v, pp0 = pp, pv0 = pv, vv0 = vv;
        double s = vv0 + r, k1 = pv0 / s, k2 = vv0 / s, y = z - v0;
        p = p0 + k1 * y;
        v = v0 + k2 * y;
        pp = pp0 - k1 * pv0;
        pv = (1 - k2) * pv0;
        vv = (1 - k2) * vv0;
        return y * y / s + Math.log(s);
    }

    /** Snapshot form {@code [p, v, pp, pv, vv]}. */
    public List<Object> toList() {
        return List.of(p, v, pp, pv, vv);
    }
}
