package goat.model;

/** The measurements of one report, in the plane (correlate.md, Track estimate). */
public final class Measurement {
    /** East, north position. */
    public final double[] z;
    /** East, north measurement variance (Track estimate, Measurement variance). */
    public final double[] r;
    public final boolean hasVel;
    /** East, north velocity. */
    public final double[] zv;

    public Measurement(double[] z, double[] r, boolean hasVel, double ve, double vn) {
        this.z = z;
        this.r = r;
        this.hasVel = hasVel;
        this.zv = new double[] {ve, vn};
    }
}
