package goat.correlate;

import goat.model.Axis;

/**
 * A move of B's prediction into A's frame before a test (correlate-assign.md, Sensor bias).
 * The method supplies it; without one, no prediction is moved.
 */
public interface FrameMove {
    /** B's prediction {east, north} moved into A's frame; the argument is left as it was. */
    Axis[] moveInto(String aSource, String bSource, Axis[] predictedB);
}
