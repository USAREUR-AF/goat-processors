package goat.io;

import goat.testkit.Check;
import goat.testkit.Fixtures;
import goat.trace.Result;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Unit tests of the io module: Json, Functions, Steps, Vectors.diff, the runner. */
public final class IoTest {
    private IoTest() {}

    public static void testJsonValues() {
        Object v = Json.parse(" {\"a\": [1, -2.5, 3e2, true, false, null, \"x\\n\\u00e9\\\"\"], \"b\": {}} ");
        Map<?, ?> m = (Map<?, ?>) v;
        List<?> a = (List<?>) m.get("a");
        Check.eq(1L, a.get(0), "integer is a Long");
        Check.eq(-2.5, a.get(1), "fraction is a Double");
        Check.eq(300.0, a.get(2), "exponent is a Double");
        Check.eq(Arrays.asList(true, false, null), a.subList(3, 6), "literals");
        Check.eq("x\né\"", a.get(6), "escapes");
        Check.eq(Map.of(), m.get("b"), "empty object");
    }

    public static void testJsonBigIntegerIsADouble() {
        Check.eq(9.223372036854776E18, Json.parse("9223372036854775808"), "outside the signed 64-bit range");
        Check.eq(Long.MAX_VALUE, Json.parse("9223372036854775807"), "the largest integer");
    }

    public static void testJsonKeyOrderKept() {
        Map<?, ?> m = (Map<?, ?>) Json.parse("{\"z\":1,\"a\":2,\"m\":3}");
        Check.eq(List.of("z", "a", "m"), List.copyOf(m.keySet()), "keys in input order");
    }

    public static void testJsonWrite() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("s", "a\"b\\c\u0001");
        m.put("n", null);
        m.put("l", List.of(1L, 2.5, true));
        Check.eq("{\"s\":\"a\\\"b\\\\c\\u0001\",\"n\":null,\"l\":[1,2.5,true]}", Json.write(m), "written");
        Check.eq(m, Json.parse(Json.write(m)), "round trip");
    }

    public static void testJsonErrors() {
        for (String bad : List.of("", "{", "[1,", "{\"a\" 1}", "tru", "\"abc", "[1 2]", "1 2", "-", "{\"a\":}"))
            Check.throwsA(IllegalArgumentException.class, () -> Json.parse(bad), "bad JSON " + bad);
    }

    public static void testFunctionsTable() {
        Check.eq(List.of("correlate", "filter", "fuse", "quality"), List.copyOf(Functions.names()), "the four functions");
        Check.throwsA(IllegalArgumentException.class, () -> Functions.fromText("sort", ""), "unknown function");
        Check.throwsA(LoadError.class, () -> Functions.load("filter", Path.of("/nonexistent-goat")), "no pack.def");
    }

    public static void testSteps() throws Exception {
        Check.eq(null, Steps.of(List.of()), "not an object");
        Check.eq(null, Steps.of(Map.of("steps", 1L)), "steps not a list");
        Processor p = Fixtures.load("filter", "filter-thin");
        Result r = Steps.apply(p, Map.of("tick", 5L));
        Check.isTrue(r.events.isEmpty(), "a tick on no entity");
    }

    public static void testDiff() {
        Check.eq(null, Vectors.diff("x", 1.0000001, 1L), "numbers to relative 1e-6");
        Check.eq("x: got 1.1, want 1", Vectors.diff("x", 1.1, 1L), "number mismatch");
        Check.eq("x.b: missing, want 2", Vectors.diff("x", Map.of("a", 1L), Map.of("a", 1L, "b", 2L)), "missing key");
        Check.eq(null, Vectors.diff("x", List.of("a"), List.of("a")), "lists");
        Check.isTrue(Vectors.diff("x", List.of("a"), List.of("a", "b")).startsWith("x: length 1, want 2"), "length");
        Check.eq("x: got null, want \"a\"", Vectors.diff("x", null, "a"), "null");
    }

    static String[] runner(String... args) throws Exception {
        PrintStream out = System.out;
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        System.setOut(new PrintStream(buf, true, StandardCharsets.UTF_8));
        try {
            Runner.run(args);
        } finally {
            System.setOut(out);
        }
        return buf.toString(StandardCharsets.UTF_8).split("\n");
    }

    /** The runner contract: one counters line, the events file, the snapshot last. */
    @SuppressWarnings("unchecked")
    public static void testRunner() throws Exception {
        Path root = Fixtures.root();
        Path vec = Vectors.list(root.resolve("packs/filter-thin/vectors")).get(0);
        Path events = Files.createTempFile("goat-events", ".jsonl");
        try {
            String[] out = runner("--function", "filter", "--pack", root.resolve("packs/filter-thin").toString(),
                    "--steps", vec.toString(), "--events", events.toString(), "--trace");
            Check.eq(1, out.length, "one line on standard output");
            Map<String, Object> c = (Map<String, Object>) Json.parse(out[0]);
            Check.eq(List.of("engine", "function", "pack", "steps", "ingest", "tick", "events", "trace_records",
                    "parse_ns", "load_ns", "run_ns"), List.copyOf(c.keySet()), "counter keys");
            Check.eq("java", c.get("engine"), "engine");
            Check.eq("filter-thin", c.get("pack"), "pack base name");
            List<String> lines = Files.readAllLines(events, StandardCharsets.UTF_8);
            Check.eq(((Long) c.get("steps")).intValue() + 1, lines.size(), "a line per step and the snapshot");
            Map<String, Object> first = (Map<String, Object>) Json.parse(lines.get(0));
            Check.eq(List.of("step", "events", "trace"), List.copyOf(first.keySet()), "step line");
            Check.isTrue(((Map<String, Object>) Json.parse(lines.get(lines.size() - 1))).containsKey("snapshot"), "snapshot last");
            Check.eq(c.get("ingest"), (Long) c.get("steps") - (Long) c.get("tick"), "ingest + tick = steps");
        } finally {
            Files.deleteIfExists(events);
        }
    }

    public static void testRunnerErrors() {
        Check.throwsA(Runner.Usage.class, () -> runner("--function", "sort", "--pack", ".", "--steps", "x"), "unknown function");
        Check.throwsA(Runner.Usage.class, () -> runner("--function", "filter"), "missing arguments");
        Check.throwsA(Runner.Usage.class, () -> runner("--bogus"), "unknown argument");
        Check.throwsA(Runner.Usage.class, () -> runner("--pack"), "argument without value");
    }
}
