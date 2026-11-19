package correlator;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/** Runs every scenario vector and load vector (spec/vector-format.md). */
public final class VectorTest {

    public static void main(String[] args) throws IOException {
        Path root = Paths.get(args.length > 0 ? args[0] : ".");
        int pass = 0, fail = 0;

        for (Path f : list(root.resolve("spec/correlate-load-vectors"))) {
            String why = runLoadVector(f);
            if (why == null) pass++;
            else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
        }
        for (Path packDir : listDirs(root.resolve("packs"))) {
            if (!packDir.getFileName().toString().startsWith("correlate-")) continue;
            for (Path f : list(packDir.resolve("vectors"))) {
                String why = runScenario(root, f);
                if (why == null) pass++;
                else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
            }
        }
        System.out.println(pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }

    @SuppressWarnings("unchecked")
    static String runLoadVector(Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(read(f));
        boolean wantError = (Boolean) v.get("expect_error");
        boolean gotError;
        try {
            Pack.parse((String) v.get("pack_def"));
            gotError = false;
        } catch (Pack.LoadError e) {
            gotError = true;
        }
        return gotError == wantError ? null : "expect_error " + wantError + ", got error " + gotError;
    }

    @SuppressWarnings("unchecked")
    static String runScenario(Path root, Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(read(f));
        Engine eng;
        try {
            eng = new Engine(Engine.loadPack(root.resolve("packs").resolve((String) v.get("pack"))));
        } catch (Pack.LoadError e) {
            return "load_pack: " + e.getMessage();
        }
        List<Object> steps = (List<Object>) v.get("steps");
        for (int k = 0; k < steps.size(); k++) {
            Map<String, Object> step = (Map<String, Object>) steps.get(k);
            Engine.Result r = step.containsKey("ingest")
                    ? eng.ingest((Map<String, Object>) step.get("ingest"))
                    : eng.tick(((Number) step.get("tick")).longValue());
            String m = diff("steps[" + k + "].expect", new ArrayList<Object>(r.events), step.get("expect"));
            if (m == null) m = diff("steps[" + k + "].trace", new ArrayList<Object>(r.trace), step.get("trace"));
            if (m != null) return m;
        }
        return diff("snapshot", eng.snapshot(), v.get("snapshot"));
    }

    /** Structural equality of vector-format.md; returns the first mismatch path, or null. */
    public static String diff(String path, Object got, Object want) {
        if (want == null || got == null) {
            return want == null && got == null ? null : mismatch(path, got, want);
        }
        if (want instanceof Number) {
            if (!(got instanceof Number)) return mismatch(path, got, want);
            double g = ((Number) got).doubleValue(), w = ((Number) want).doubleValue();
            return Math.abs(g - w) <= 1e-6 * Math.max(1, Math.abs(w)) ? null : mismatch(path, got, want);
        }
        if (want instanceof Map) {
            if (!(got instanceof Map)) return mismatch(path, got, want);
            Map<?, ?> g = (Map<?, ?>) got, w = (Map<?, ?>) want;
            for (Object key : w.keySet()) {
                if (!g.containsKey(key)) return path + "." + key + ": missing, want " + Json.write(w.get(key));
                String m = diff(path + "." + key, g.get(key), w.get(key));
                if (m != null) return m;
            }
            for (Object key : g.keySet())
                if (!w.containsKey(key)) return path + "." + key + ": unexpected " + Json.write(g.get(key));
            return null;
        }
        if (want instanceof List) {
            if (!(got instanceof List)) return mismatch(path, got, want);
            List<?> g = (List<?>) got, w = (List<?>) want;
            for (int k = 0; k < Math.min(g.size(), w.size()); k++) {
                String m = diff(path + "[" + k + "]", g.get(k), w.get(k));
                if (m != null) return m;
            }
            if (g.size() != w.size())
                return path + ": length " + g.size() + ", want " + w.size() + "; got " + Json.write(got);
            return null;
        }
        return want.equals(got) ? null : mismatch(path, got, want);
    }

    private static String mismatch(String path, Object got, Object want) {
        return path + ": got " + Json.write(got) + ", want " + Json.write(want);
    }

    private static String read(Path f) throws IOException {
        return new String(Files.readAllBytes(f), StandardCharsets.UTF_8);
    }

    private static List<Path> list(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) return List.of();
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(p -> p.toString().endsWith(".json")).sorted().collect(Collectors.toList());
        }
    }

    private static List<Path> listDirs(Path dir) throws IOException {
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(Files::isDirectory).sorted().collect(Collectors.toList());
        }
    }
}
