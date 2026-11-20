package goat.testkit;

import goat.io.Functions;
import goat.io.Json;
import goat.io.LoadError;
import goat.io.PackFile;
import goat.io.Processor;
import goat.io.Steps;
import goat.io.Vectors;
import goat.trace.Result;

import java.io.IOException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** The repository's packs and vectors, and running steps through a processor. */
public final class Fixtures {
    private Fixtures() {}

    /** The repository root: the system property {@code goat.root}, else the current directory. */
    public static Path root() {
        return Paths.get(System.getProperty("goat.root", ".")).toAbsolutePath().normalize();
    }

    /** engines/java/test/fixtures. */
    public static Path fixtures() {
        return root().resolve("engines/java/test/fixtures");
    }

    public static String packText(String pack) throws IOException {
        return PackFile.read(root().resolve("packs").resolve(pack));
    }

    public static Processor load(String function, String pack) throws LoadError {
        return Functions.load(function, root().resolve("packs").resolve(pack));
    }

    /** The scenario vectors of a pack, parsed. */
    @SuppressWarnings("unchecked")
    public static List<Map<String, Object>> vectors(String pack) throws IOException {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Path f : Vectors.list(root().resolve("packs").resolve(pack).resolve("vectors")))
            out.add((Map<String, Object>) Json.parse(Vectors.read(f)));
        return out;
    }

    /** Every pack directory name of a function (correlate-*, filter-*, ...). */
    public static List<String> packs(String function) throws IOException {
        List<String> out = new ArrayList<>();
        for (Path d : Vectors.listDirs(root().resolve("packs"), function + "-")) out.add(d.getFileName().toString());
        return out;
    }

    /** The steps of a vector. */
    @SuppressWarnings("unchecked")
    public static List<Map<String, Object>> steps(Map<String, Object> vector) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Object s : (List<Object>) vector.get("steps")) out.add((Map<String, Object>) s);
        return out;
    }

    /**
     * Runs the steps through the processor: the JSON text of each step's events and trace, then
     * of the snapshot, one string per line as the runner writes them.
     */
    public static List<String> run(Processor p, List<Map<String, Object>> steps) {
        List<String> out = new ArrayList<>();
        for (Map<String, Object> step : steps) {
            Result r = Steps.apply(p, step);
            out.add(Json.write(r.events) + " " + Json.write(r.trace));
        }
        out.add(Json.write(p.snapshot()));
        return out;
    }
}
