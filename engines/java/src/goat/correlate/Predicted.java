package goat.correlate;

import goat.model.Axis;

/** B's filter predicted to time t (correlate.md, Track estimate, Prediction). */
public final class Predicted {
    public final Axis east, north;

    public Predicted(Entity b, long t) {
        Axis[] ax = b.filter.predicted((t - b.lastTime) / 1000.0);
        east = ax[0];
        north = ax[1];
    }

    /**
     * B predicted to t to be compared with another entity (Track estimate, Measurement
     * variance): B's timing variance added to the predicted pp on each axis, before any other
     * change to the prediction.
     */
    public static Predicted forComparison(Entity b, long t) {
        Predicted pr = new Predicted(b, t);
        pr.east.pp = pr.east.pp + b.timingVar[0];
        pr.north.pp = pr.north.pp + b.timingVar[1];
        return pr;
    }
}
