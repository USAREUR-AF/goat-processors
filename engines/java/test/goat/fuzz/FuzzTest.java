package goat.fuzz;

import goat.io.Functions;
import goat.io.Json;
import goat.io.LoadError;
import goat.io.Vectors;
import goat.testkit.Check;
import goat.testkit.Fixtures;
import goat.testkit.Rng;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Fuzzing of the input parsers, the JSON reader and the four pack.def readers, with a seeded
 * generator (goat.testkit.Rng) and a bounded run: each test stops after its case count or its
 * time budget (4 s; 1 s per pack reader), whichever comes first, but runs at least 200 cases. A parser may accept or refuse an input; it must refuse with
 * its own error (IllegalArgumentException for JSON, LoadError for a pack), never another
 * exception, and give the same answer twice. Set {@code -Dgoat.fuzz.cases=N} for a longer run.
 */
public final class FuzzTest {
    private FuzzTest() {}

    static final long BUDGET_NS = 4_000_000_000L;
    /** Cases run whatever the time, so a slow machine still fuzzes every parser. */
    static final int MIN_CASES = 200;

    static int cases(int dflt) {
        return Integer.getInteger("goat.fuzz.cases", dflt);
    }

    /** Text mutations: flip, delete, duplicate or insert characters, cut, splice. */
    static String mutate(String s, Rng r, String alphabet) {
        StringBuilder b = new StringBuilder(s);
        int edits = 1 + r.below(4);
        for (int e = 0; e < edits; e++) {
            int at = b.length() == 0 ? 0 : r.below(b.length());
            switch (r.below(6)) {
                case 0: if (b.length() > 0) b.setCharAt(at, alphabet.charAt(r.below(alphabet.length()))); break;
                case 1: if (b.length() > 0) b.deleteCharAt(at); break;
                case 2: b.insert(at, alphabet.charAt(r.below(alphabet.length()))); break;
                case 3: b.setLength(at); break;
                case 4: if (b.length() > 0) { int to = Math.min(b.length(), at + r.below(20)); b.insert(at, b.substring(at, to)); } break;
                default: b.insert(at, (char) r.below(0x110)); break;
            }
        }
        return b.toString();
    }

    static final String JSON_ALPHABET = "{}[]\",:\\/0123456789.eE+-truefalsnul \t\nabcxyzé";

    /** A random JSON value, depth-bounded. */
    static Object randomValue(Rng r, int depth) {
        switch (depth <= 0 ? r.below(5) : r.below(7)) {
            case 0: return null;
            case 1: return r.chance(0.5);
            case 2: return r.next() >> r.below(64);
            case 3: {
                double d = (r.unit() - 0.5) * Math.pow(10, r.below(40) - 20);
                return d;
            }
            case 4: {
                StringBuilder b = new StringBuilder();
                int n = r.below(8);
                for (int i = 0; i < n; i++) b.append((char) (r.chance(0.8) ? 0x20 + r.below(0x5f) : r.below(0x3000)));
                return b.toString();
            }
            case 5: {
                List<Object> l = new ArrayList<>();
                int n = r.below(5);
                for (int i = 0; i < n; i++) l.add(randomValue(r, depth - 1));
                return l;
            }
            default: {
                Map<String, Object> m = new LinkedHashMap<>();
                int n = r.below(5);
                for (int i = 0; i < n; i++) m.put("k" + r.below(10), randomValue(r, depth - 1));
                return m;
            }
        }
    }

    /** write then parse gives the value back. */
    public static void testJsonRoundTrip() {
        Rng r = new Rng(101);
        long start = System.nanoTime();
        for (int i = 0; i < cases(3000) && (i < MIN_CASES || System.nanoTime() - start < BUDGET_NS); i++) {
            Object v = randomValue(r, 4);
            String text = Json.write(v);
            Check.eq(text, Json.write(Json.parse(text)), "round trip");
        }
    }

    /** Mutated vector files and random text: a value or IllegalArgumentException, the same twice. */
    public static void testJsonMutations() throws Exception {
        Rng r = new Rng(202);
        List<String> seeds = new ArrayList<>();
        for (Path f : Vectors.list(Fixtures.root().resolve("spec/correlate-load-vectors"))) seeds.add(Vectors.read(f));
        for (String pack : List.of("correlate-gnn", "filter-thin", "fuse-best", "quality-time"))
            for (Path f : Vectors.list(Fixtures.root().resolve("packs").resolve(pack).resolve("vectors")))
                seeds.add(Vectors.read(f).substring(0, Math.min(3000, Vectors.read(f).length())));
        long start = System.nanoTime();
        int refused = 0, n = cases(20000);
        for (int i = 0; i < n && (i < MIN_CASES || System.nanoTime() - start < BUDGET_NS); i++) {
            String text = i % 10 == 0 ? mutate("", r, JSON_ALPHABET) + mutate("", r, JSON_ALPHABET)
                    : mutate(r.pick(seeds), r, JSON_ALPHABET);
            String first = outcome(text), second = outcome(text);
            Check.eq(first, second, "deterministic");
            if (first.startsWith("refused")) refused++;
        }
        Check.isTrue(refused > 0, "some inputs refused");
    }

    static String outcome(String text) {
        try {
            return "parsed " + Json.write(Json.parse(text));
        } catch (IllegalArgumentException e) {
            return "refused " + e.getMessage();
        } catch (RuntimeException e) {
            throw new AssertionError("JSON reader threw " + e + " on: " + clip(text), e);
        }
    }

    static final String PACK_ALPHABET = " \t\n\r#=.,;-+0123456789eEabcdefghijklmnopqrstuvwxyz_\u0001";
    static final List<String> TOKENS = List.of("pack", "version", "method", "assign", "confirm", "filter", "gate",
            "hold", "rule", "when", "not", "window", "time_default", "bias", "margin", "hypotheses", "kinematics",
            "attribute", "source", "stale_ms", "default", "keep", "drop", "=", "x=1", "max_m=1e9", "key=",
            "error_ms=-0", "state=drifting", "-1", "0", "1.", ".5", "99999999999999999999", "in=", "vertices=0,0;1,1;2,0");

    /** A pack.def mutation: whole lines dropped, repeated or swapped, tokens replaced, characters edited. */
    static String mutatePack(String text, Rng r) {
        List<String> lines = new ArrayList<>(List.of(text.split("\n", -1)));
        int edits = 1 + r.below(3);
        for (int e = 0; e < edits && !lines.isEmpty(); e++) {
            int i = r.below(lines.size());
            switch (r.below(5)) {
                case 0: lines.remove(i); break;
                case 1: lines.add(r.below(lines.size() + 1), lines.get(i)); break;
                case 2: {
                    String[] tok = lines.get(i).split(" ", -1);
                    tok[r.below(tok.length)] = r.pick(TOKENS);
                    lines.set(i, String.join(" ", tok));
                    break;
                }
                case 3: lines.set(i, lines.get(i) + " " + r.pick(TOKENS)); break;
                default: lines.set(i, mutate(lines.get(i), r, PACK_ALPHABET));
            }
        }
        return String.join("\n", lines);
    }

    /** Every function's pack.def reader on mutated packs and load vectors. */
    @SuppressWarnings("unchecked")
    public static void testPackMutations() throws Exception {
        Rng r = new Rng(303);
        int perFunction = cases(4000);
        for (String fn : Functions.names()) {
            long start = System.nanoTime();
            List<String> seeds = new ArrayList<>();
            for (String pack : Fixtures.packs(fn)) seeds.add(Fixtures.packText(pack));
            for (Path f : Vectors.list(Fixtures.root().resolve("spec/" + fn + "-load-vectors")))
                seeds.add((String) ((Map<String, Object>) Json.parse(Vectors.read(f))).get("pack_def"));
            int loaded = 0, refused = 0;
            for (int i = 0; i < perFunction && (i < MIN_CASES || System.nanoTime() - start < BUDGET_NS / 4); i++) {
                String text = mutatePack(r.pick(seeds), r);
                String first = load(fn, text), second = load(fn, text);
                Check.eq(first, second, fn + " deterministic");
                if (first.startsWith("loaded")) loaded++;
                else refused++;
            }
            Check.isTrue(loaded > 0 && refused > 0, fn + ": both outcomes seen, " + loaded + " loaded, " + refused + " refused");
        }
    }

    static String clip(String text) {
        return text.length() <= 400 ? text : text.substring(0, 400) + "...";
    }

    static String load(String fn, String text) {
        try {
            Functions.fromText(fn, text);
            return "loaded";
        } catch (LoadError e) {
            return "refused " + e.getMessage();
        } catch (RuntimeException e) {
            throw new AssertionError(fn + " pack reader threw " + e + " on:\n" + clip(text), e);
        }
    }
}
