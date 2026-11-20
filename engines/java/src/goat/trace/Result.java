package goat.trace;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** What one ingest or tick returns: its events, then its trace records (spec/vector-format.md). */
public final class Result {
    public final List<Map<String, Object>> events = new ArrayList<>();
    public final List<Map<String, Object>> trace = new ArrayList<>();
}
