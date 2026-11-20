package goat.correlate;

import goat.model.Axis;

/** B's filter predicted to time t (correlate.md, Track estimate, Prediction). A value. */
public final class Predicted {
    public final Axis east, north;

    public Predicted(Axis east, Axis north) {
        this.east = east;
        this.north = north;
    }

    /** B predicted to t. */
    public static Predicted of(Entity b, long t) {
        Axis[] ax = b.filter.predicted((t - b.lastTime) / 1000.0);
        return new Predicted(ax[0], ax[1]);
    }

    /**
     * B predicted to t to be compared with another entity (Track estimate, Measurement
     * variance): B's timing variance added to the predicted pp on each axis, before any other
     * change to the prediction.
     */
    public static Predicted forComparison(Entity b, long t) {
        Predicted pr = of(b, t);
        return new Predicted(pr.east.plusPp(b.timingVar[0]), pr.north.plusPp(b.timingVar[1]));
    }

    public Axis[] axes() {
        return new Axis[] {east, north};
    }
}
