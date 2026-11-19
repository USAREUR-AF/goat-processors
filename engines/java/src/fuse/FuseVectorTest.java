package fuse;

import correlator.Json;
import correlator.VectorTest;

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
 * Runs every fuse load vector (spec/fuse-load-vectors/) and scenario vector
 * (packs/fuse-NAME/vectors/), compared as spec/vector-format.md says; prints the
 * path of the first mismatch of each failing vector.
 */
public final class FuseVectorTest {

    public static void main(String[] args) throws IOException {
        Path root = Paths.get(args.length > 0 ? args[0] : ".");
        int pass = 0, fail = 0;
        for (Path f : json(root.resolve("spec/fuse-load-vectors"))) {
            String why = runLoadVector(f);
            if (why == null) pass++;
            else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
        }
        for (Path packDir : dirs(root.resolve("packs"))) {
            if (!packDir.getFileName().toString().startsWith("fuse-")) continue;
            for (Path f : json(packDir.resolve("vectors"))) {
                String why = runScenario(root, f);
                if (why == null) pass++;
                else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
            }
        }
        System.out.println("fuse: " + pass + " passed, " + fail + " failed");
        System.exit(fail == 0 ? 0 : 1);
    }

    @SuppressWarnings("unchecked")
    static String runLoadVector(Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(read(f));
        boolean wantError = (Boolean) v.get("expect_error");
        boolean gotError;
        try {
            FusePack.parse((String) v.get("pack_def"));
            gotError = false;
        } catch (FusePack.LoadError e) {
            gotError = true;
        }
        return gotError == wantError ? null : "expect_error " + wantError + ", got error " + gotError;
    }

    @SuppressWarnings("unchecked")
    static String runScenario(Path root, Path f) throws IOException {
        Map<String, Object> v = (Map<String, Object>) Json.parse(read(f));
        Fuse eng;
        try {
            eng = new Fuse(Fuse.loadPack(root.resolve("packs").resolve((String) v.get("pack"))));
        } catch (FusePack.LoadError e) {
            return "load_pack: " + e.getMessage();
        }
        List<Object> steps = (List<Object>) v.get("steps");
        for (int k = 0; k < steps.size(); k++) {
            Map<String, Object> step = (Map<String, Object>) steps.get(k);
            Fuse.Result r = step.containsKey("ingest")
                    ? eng.ingest((Map<String, Object>) step.get("ingest"))
                    : eng.tick(((Number) step.get("tick")).longValue());
            String m = VectorTest.diff("steps[" + k + "].expect", new ArrayList<Object>(r.events), step.get("expect"));
            if (m == null) m = VectorTest.diff("steps[" + k + "].trace", new ArrayList<Object>(r.trace), step.get("trace"));
            if (m != null) return m;
        }
        return VectorTest.diff("snapshot", eng.snapshot(), v.get("snapshot"));
    }

    private static String read(Path f) throws IOException {
        return new String(Files.readAllBytes(f), StandardCharsets.UTF_8);
    }

    private static List<Path> json(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) return List.of();
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(p -> p.toString().endsWith(".json")).sorted().collect(Collectors.toList());
        }
    }

    private static List<Path> dirs(Path dir) throws IOException {
        try (Stream<Path> s = Files.list(dir)) {
            return s.filter(Files::isDirectory).sorted().collect(Collectors.toList());
        }
    }
}
