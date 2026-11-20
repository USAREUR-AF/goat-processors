package goat.model;

/** The pack's {@code filter} line and the optional {@code maneuver} line (correlate.md, Pack). */
public final class FilterParams {
    public final double accelVar, defaultCe, velSigma, unknownVel;
    /** Two-model filter: present when the pack has a {@code maneuver} line. */
    public final boolean maneuver;
    public final double maneuverAccelVar, pEnter, pLeave;

    public FilterParams(double accelVar, double defaultCe, double velSigma, double unknownVel,
                        boolean maneuver, double maneuverAccelVar, double pEnter, double pLeave) {
        this.accelVar = accelVar;
        this.defaultCe = defaultCe;
        this.velSigma = velSigma;
        this.unknownVel = unknownVel;
        this.maneuver = maneuver;
        this.maneuverAccelVar = maneuverAccelVar;
        this.pEnter = pEnter;
        this.pLeave = pLeave;
    }
}
