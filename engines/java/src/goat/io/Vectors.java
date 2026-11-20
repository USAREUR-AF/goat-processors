package goat.io;

import goat.trace.Result;

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

/**
 * spec/vector-format.md for one function: every load vector of {@code spec/<f>-load-vectors/}
 * and every scenario vector of {@code packs/<f>-*}{@code /vectors/}. Prints the first mismatch of
 * each failing vector, then {@code <f>: N passed, M failed}; exits non-zero on any failure.
 */
public final class Vectors {
    private Vectors() {}

    /** {@code Vectors <function> [root]}. */
    public static void main(String[] args) throws IOException {
        System.exit(run(args[0], Paths.get(args.length > 1 ? args[1] : ".")) == 0 ? 0 : 1);
    }

    /** Runs every vector of the function under root; returns the number that failed. */
    public static int run(String function, Path root) throws IOException {
        int pass = 0, fail = 0;
        for (Path f : list(root.resolve("spec/" + function + "-load-vectors"))) {
            String why = runLoadVector(function, f);
            if (why == null) pass++;
            else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
        }
        for (Path packDir : listDirs(root.resolve("packs"), function + "-")) {
            for (Path f : list(packDir.resolve("vectors"))) {
                String why = runScenario(function, root, f);
                if (why == null) pass++;
                else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
            }
        }
        System.out.println(function + ": " + pass + " passed, " + fail + " failed");
        return fail;
    }

    /** A load vector: parsing pack_def fails exactly when expect_error is true. */
    @SuppressWarnings("unchecked")
    public static String runLoadVector(String function, Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(read(f));
        boolean wantError = (Boolean) v.get("expect_error");
        String error = null;
        try {
            Functions.fromText(function, (String) v.get("pack_def"));
        } catch (LoadError e) {
            error = e.getMessage();
        }
        if ((error != null) == wantError) return null;
        return "expect_error " + wantError + ", got " + (error == null ? "no error" : "error: " + error);
    }

    /** A scenario vector: each step's events and trace, then the final snapshot. */
    @SuppressWarnings("unchecked")
    public static String runScenario(String function, Path root, Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(read(f));
        Processor p;
        try {
            p = Functions.load(function, root.resolve("packs").resolve((String) v.get("pack")));
        } catch (LoadError e) {
            return "load_pack: " + e.getMessage();
        }
        List<Object> steps = (List<Object>) v.get("steps");
        for (int k = 0; k < steps.size(); k++) {
            Map<String, Object> step = (Map<String, Object>) steps.get(k);
            Result r = Steps.apply(p, step);
            String m = diff("steps[" + k + "].expect", new ArrayList<Object>(r.events), step.get("expect"));
            if (m == null) m = diff("steps[" + k + "].trace", new ArrayList<Object>(r.trace), step.get("trace"));
            if (m != null) return m;
        }
        return diff("snapshot", p.snapshot(), v.get("snapshot"));
    }

    /** Structural equality of vector-format.md (numbers to relative 1e-6); the first mismatch path, or null. */
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

    public static String read(Path f) throws IOException {
        return new String(Files.readAllBytes(f), StandardCharsets.UTF_8);
    }

    /** The .json files of dir, sorted; none when dir does not exist. */
    public static List<Path> list(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) return List.of();
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(p -> p.toString().endsWith(".json")).sorted().collect(Collectors.toList());
        }
    }

    /** The subdirectories of dir whose name starts with prefix, sorted. */
    public static List<Path> listDirs(Path dir, String prefix) throws IOException {
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(Files::isDirectory)
                    .filter(p -> p.getFileName().toString().startsWith(prefix))
                    .sorted().collect(Collectors.toList());
        }
    }
}
