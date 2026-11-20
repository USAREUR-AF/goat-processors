package goat.correlate;

import goat.trace.Result;

import java.util.Map;

/**
 * A correlate method (correlate.md, Pack, {@code method}): what happens after a report has
 * updated its entity, on each tick, and in the snapshot. The entities, their filters and the
 * tests are the {@link Correlator}'s.
 */
public interface Method {
    /** An accepted report of entity a, after its filter update. */
    void reported(Entity a, Result res);

    /** correlate.md, Restart: entity key's filter started again from this report. */
    default void restarted(String key) {}

    Result tick(long now);

    Map<String, Object> snapshot();

    /** The move into another source's frame used by the tests, or null. */
    default FrameMove frameMove() {
        return null;
    }
}
