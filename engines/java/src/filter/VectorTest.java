package filter;

import correlator.Engine.Result;
import correlator.Json;
import java.io.IOException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Runs every filter scenario vector (packs/filter-*) and filter load vector
 * (spec/filter-load-vectors) with the comparison of spec/vector-format.md.
 * A failing vector prints the path of its first mismatch.
 */
public final class VectorTest {

    public static void main(String[] args) throws IOException {
        Path root = Paths.get(args.length > 0 ? args[0] : ".");
        int pass = 0, fail = 0;

        for (Path f : correlator.VectorTest.list(root.resolve("spec/filter-load-vectors"))) {
            String why = runLoadVector(f);
            if (why == null) pass++;
            else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
        }
        for (Path packDir : correlator.VectorTest.listDirs(root.resolve("packs"), "filter-")) {
            for (Path f : correlator.VectorTest.list(packDir.resolve("vectors"))) {
                String why = runScenario(root, f);
                if (why == null) pass++;
                else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
            }
        }
        System.out.println("filter: " + pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }

    /** Load vectors: parsing pack_def fails exactly when expect_error is true. */
    @SuppressWarnings("unchecked")
    static String runLoadVector(Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(correlator.VectorTest.read(f));
        boolean wantError = (Boolean) v.get("expect_error");
        String error = null;
        try {
            Pack.parse((String) v.get("pack_def"));
        } catch (Pack.LoadError e) {
            error = e.getMessage();
        }
        if ((error != null) == wantError) return null;
        return "expect_error " + wantError + ", got " + (error == null ? "no error" : "error: " + error);
    }

    /** Scenario vectors: each step's events and trace, then the final snapshot. */
    @SuppressWarnings("unchecked")
    static String runScenario(Path root, Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(correlator.VectorTest.read(f));
        Filter filter;
        try {
            filter = new Filter(Filter.loadPack(root.resolve("packs").resolve((String) v.get("pack"))));
        } catch (Pack.LoadError e) {
            return "load_pack: " + e.getMessage();
        }
        List<Object> steps = (List<Object>) v.get("steps");
        for (int k = 0; k < steps.size(); k++) {
            Map<String, Object> step = (Map<String, Object>) steps.get(k);
            Result r = step.containsKey("ingest")
                    ? filter.ingest((Map<String, Object>) step.get("ingest"))
                    : filter.tick(((Number) step.get("tick")).longValue());
            String m = correlator.VectorTest.diff("steps[" + k + "].expect", new ArrayList<Object>(r.events), step.get("expect"));
            if (m == null) m = correlator.VectorTest.diff("steps[" + k + "].trace", new ArrayList<Object>(r.trace), step.get("trace"));
            if (m != null) return m;
        }
        return correlator.VectorTest.diff("snapshot", filter.snapshot(), v.get("snapshot"));
    }
}
