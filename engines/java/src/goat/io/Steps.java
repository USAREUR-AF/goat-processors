package goat.io;

import goat.trace.Result;

import java.util.List;
import java.util.Map;

/** spec/vector-format.md, steps: each holds {@code ingest} (a report) or {@code tick} (now_ms). */
public final class Steps {
    private Steps() {}

    /** The steps of a parsed steps file (a JSON object whose {@code steps} is a list), or null. */
    @SuppressWarnings("unchecked")
    public static List<Object> of(Object parsed) {
        if (!(parsed instanceof Map)) return null;
        Object s = ((Map<String, Object>) parsed).get("steps");
        return s instanceof List ? (List<Object>) s : null;
    }

    /** True when the step is an {@code ingest} step. */
    public static boolean isIngest(Map<String, Object> step) {
        return step.containsKey("ingest");
    }

    /** One step: {@code ingest} for an ingest step, else {@code tick}. */
    @SuppressWarnings("unchecked")
    public static Result apply(Processor p, Map<String, Object> step) {
        return isIngest(step)
                ? p.ingest((Map<String, Object>) step.get("ingest"))
                : p.tick(((Number) step.get("tick")).longValue());
    }
}
