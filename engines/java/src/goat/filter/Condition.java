package goat.filter;

import java.util.List;

/**
 * One `when` line of a pack (filter.md, Conditions and Pack). Only the fields of
 * the condition's parameters are set; the others stay null.
 */
public final class Condition {
    /** The condition name as written: circle, polygon, near, env, ... */
    public final String test;
    /** Written with `not`. */
    public final boolean negated;

    Double lat, lon, radiusM;            // circle; radius_m also near
    double[] vertexLat, vertexLon;       // polygon, pack order
    String reference;                    // near
    Long maxAgeMs;                       // near
    List<String> in;                     // env, affiliation, source, uid, key form in
    String name;                         // key, has
    String eq;                           // key form eq
    Double min, max;                     // key form range, speed, altitude
    Long minMs;                          // interval

    Condition(String test, boolean negated) {
        this.test = test;
        this.negated = negated;
    }
}
