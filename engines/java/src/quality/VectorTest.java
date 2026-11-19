package quality;

import correlator.Json;

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

import static correlator.VectorTest.diff;

/**
 * Runs every quality load vector (spec/quality-load-vectors/) and every quality
 * scenario vector (packs/quality-*&#47;vectors/), compared as spec/vector-format.md
 * states; prints the path of each failing vector's first mismatch.
 */
public final class VectorTest {

    public static void main(String[] args) throws IOException {
        Path root = Paths.get(args.length > 0 ? args[0] : ".");
        int pass = 0, fail = 0;

        for (Path f : list(root.resolve("spec/quality-load-vectors"))) {
            String why = runLoadVector(f);
            if (why == null) pass++;
            else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
        }
        for (Path packDir : listDirs(root.resolve("packs"))) {
            if (!packDir.getFileName().toString().startsWith("quality-")) continue;
            for (Path f : list(packDir.resolve("vectors"))) {
                String why = runScenario(root, f);
                if (why == null) pass++;
                else { fail++; System.out.println("FAIL " + root.relativize(f) + ": " + why); }
            }
        }
        System.out.println("quality: " + pass + " passed, " + fail + " failed");
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
