package goat.io;

import goat.trace.Result;

import java.util.Map;

/**
 * The one entry point shape of every function (correlate, filter, fuse, quality): a processor
 * made from a loaded pack takes one report at a time ({@link #ingest}), the clock
 * ({@link #tick}), returns events and trace records from each, and gives its {@link #snapshot}.
 * The only clock is the input's.
 */
public interface Processor {
    Result ingest(Map<String, Object> report);

    Result tick(long nowMs);

    Map<String, Object> snapshot();
}
