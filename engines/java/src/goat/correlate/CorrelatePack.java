package goat.correlate;

import goat.io.LoadError;
import goat.model.FilterParams;
import goat.model.Report;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** A loaded pack (spec: Pack). */
public final class CorrelatePack {
    /** One test line: a registered test kind and its parameters. */
    public static final class Test {
        public final TestKind kind;
        public final String name;
        public final Map<String, Double> num = new LinkedHashMap<>();
        public String key;

        Test(TestKind kind) {
            this.kind = kind;
            this.name = kind.name;
        }

        public double p(String param) {
            return num.get(param);
        }
    }

    public String name;
    public String version;
    public double accelVar, defaultCe, velSigma, unknownVel;
    public final List<Test> gate = new ArrayList<>();
    public final List<Test> confirm = new ArrayList<>();
    public final List<Test> hold = new ArrayList<>();
    public long confirmCount, holdFailures, staleMs;
    /**
     * correlate.md, Stale time of a source: the {@code stale_rate factor=<k> floor_ms=<f>
     * ceiling_ms=<c> samples=<n>} line, when present (in place of {@code stale_ms}).
     */
    public boolean staleRate = false;
    public double staleFactor;
    public long staleFloor, staleCeiling, staleSamples;
    /**
     * correlate.md, Association, Sequential test: the {@code sprt false=<p> missed=<p> pos_m=<m>
     * vel_ms=<m/s> hae_sigma_m=<m>} line, when present (method confirm only).
     */
    public boolean sprt = false;
    public double sprtFalse, sprtMissed, sprtPos, sprtVel, sprtHaeSigma;
    public boolean sameSourceAllow = false;
    /** correlate.md, Pack: {@code output fused | priority | latest}, {@code fused} without the line. */
    public String output = "fused";
    public final Map<String, Long> priority = new LinkedHashMap<>();
    /** Spec: Pack, `method`: a registered method, {@code confirm} without the line. */
    public String method = Registry.DEFAULT_METHOD;
    /** The directives the file holds, for the checks made once the whole file is read. */
    public final Set<String> seen = new HashSet<>();
    /** The registry the pack was read against: its tests and methods. */
    public final Registry registry;
    public double newCost, keepBonus;
    /** correlate-assign.md, Window: {@code window <n>} and {@code hypotheses <k>}, both default 1. */
    public long window = 1, hypotheses = 1;
    /** correlate.md, Two-model filter: the {@code maneuver} line, when present. */
    public boolean maneuver = false;
    public double maneuverAccelVar, pEnter, pLeave;
    /** correlate.md, Restart: the {@code restart gate=<g>} line, when present. */
    public boolean restart = false;
    public double restartGate;
    /** correlate-assign.md, Sensor bias: the {@code bias sigma_m=<s> floor_m=<f> gate=<g>} line, when present. */
    public boolean bias = false;
    public double biasSigma, biasFloor, biasGate;
    /**
     * correlate-assign.md, Sensor bias, "Time offset": the {@code time_offset sigma_ms=<t>} line,
     * when present.
     */
    public boolean timeOffset = false;
    public double timeOffsetSigmaMs;
    /**
     * correlate.md, Reports, "Time quality": the {@code time_default} lines, by source id. Each
     * holds the keys the line gives: {@code error_ms} (a Double) and/or {@code state} (a String).
     */
    public final Map<String, Map<String, Object>> timeDefault = new LinkedHashMap<>();
    /** correlate-assign.md, Window: the {@code margin <m>} line, when present. */
    public boolean margin = false;
    public double marginValue;

    private static final List<String> FILTER = List.of("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms");
    private static final List<String> MANEUVER = List.of("accel_var", "p_enter", "p_leave");
    private static final List<String> RESTART = List.of("gate");
    private static final List<String> STALE_RATE = List.of("factor", "floor_ms", "ceiling_ms", "samples");
    /** correlate.md, Reports, "Time quality": the three clock states. */
    public static final Set<String> TIME_STATES = Report.TIME_STATES;

    /** The directives every method takes (correlate.md, Pack); each method adds its own. */
    static final List<Directive> SHARED = List.of(
            new Directive("pack", false, (pk, tok, ln) -> pk.name = one(tok, ln)),
            new Directive("version", false, (pk, tok, ln) -> pk.version = one(tok, ln)),
            new Directive("method", false, CorrelatePack::methodLine),
            new Directive("filter", false, CorrelatePack::filterLine),
            new Directive("stale_ms", false, (pk, tok, ln) -> pk.staleMs = integer(one(tok, ln), ln)),
            new Directive("stale_rate", false, CorrelatePack::staleRateLine),
            new Directive("maneuver", false, CorrelatePack::maneuverLine),
            new Directive("restart", false, CorrelatePack::restartLine),
            new Directive("gate", true, (pk, tok, ln) -> pk.gate.add(test(pk, tok, ln))),
            new Directive("time_default", true, CorrelatePack::timeDefaultLine));

    private static final Pattern DECIMAL = Pattern.compile("[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?");
    private static final Pattern INTEGER = Pattern.compile("[+-]?[0-9]+");

    /** The filter and maneuver lines, for the track estimate. */
    public FilterParams filter;

    public static LoadError err(int line, String m) {
        return new LoadError("pack.def line " + line + ": " + m);
    }

    public static LoadError err(String m) {
        return new LoadError("pack.def: " + m);
    }

    public static CorrelatePack load(Path dir) throws LoadError {
        try {
            return parse(new String(Files.readAllBytes(dir.resolve("pack.def")), StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw err("cannot read " + dir + ": " + e.getMessage());
        }
    }

    private CorrelatePack(Registry registry) {
        this.registry = registry;
    }

    /** Reads pack.def text against the standard registry. */
    public static CorrelatePack parse(String text) throws LoadError {
        return parse(text, Registry.STANDARD);
    }

    /** Reads pack.def text against a registry: its tests, methods and directives. */
    public static CorrelatePack parse(String text, Registry registry) throws LoadError {
        CorrelatePack pk = new CorrelatePack(registry);
        Set<String> seen = pk.seen;
        Map<String, Integer> firstLine = new LinkedHashMap<>();
        String[] lines = text.split("\n", -1);
        for (int n = 0; n < lines.length; n++) {
            int ln = n + 1;
            String line = lines[n];
            int hash = line.indexOf('#');
            if (hash >= 0) line = line.substring(0, hash);
            line = line.strip();
            if (line.isEmpty()) continue;
            String[] tok = line.split("\\s+");
            String dir = tok[0];
            Directive d = registry.directive(dir);
            if (d == null) throw err(ln, "unknown directive " + dir);
            if (!seen.add(dir) && !d.repeating) throw err(ln, "repeated directive " + dir);
            firstLine.putIfAbsent(dir, ln);
            d.parser.parse(pk, tok, ln);
        }
        MethodKind method = registry.method(pk.method);
        for (Map.Entry<String, Integer> d : firstLine.entrySet()) {
            String owner = registry.ownerOf(d.getKey());
            if (owner != null && !owner.equals(method.name))
                throw err(d.getValue(), d.getKey() + " is not a directive of method " + method.name);
        }
        for (String r : method.required)
            if (!seen.contains(r)) throw err("missing directive " + r);
        // correlate.md, Pack: one of stale_ms and stale_rate, never both, with either method.
        if (seen.contains("stale_ms") == seen.contains("stale_rate"))
            throw err("one of stale_ms and stale_rate is required, never both");
        if (pk.maneuver && !(pk.maneuverAccelVar > pk.accelVar))
            throw err("maneuver accel_var must be above filter accel_var");
        method.check.check(pk);
        pk.filter = new FilterParams(pk.accelVar, pk.defaultCe, pk.velSigma, pk.unknownVel,
                pk.maneuver, pk.maneuverAccelVar, pk.pEnter, pk.pLeave);
        return pk;
    }

    // ---- the shared directives ----

    private static void methodLine(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        String v = one(tok, ln);
        if (pk.registry.method(v) == null)
            throw err(ln, "method is " + String.join(" or ", pk.registry.methods().keySet()));
        pk.method = v;
    }

    private static void filterLine(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        Map<String, String> kv = params(tok, 1, ln);
        if (!kv.keySet().equals(new HashSet<>(FILTER))) throw err(ln, "filter takes " + FILTER);
        // correlate.md, Pack: accel_var 0 or above, the others above 0.
        pk.accelVar = nonNegative(dec(kv.get("accel_var"), ln), "accel_var", ln);
        pk.defaultCe = positive(dec(kv.get("default_ce_m"), ln), "default_ce_m", ln);
        pk.velSigma = positive(dec(kv.get("vel_sigma_ms"), ln), "vel_sigma_ms", ln);
        pk.unknownVel = positive(dec(kv.get("unknown_vel_ms"), ln), "unknown_vel_ms", ln);
    }

    private static void maneuverLine(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        Map<String, String> kv = params(tok, 1, ln);
        if (!kv.keySet().equals(new HashSet<>(MANEUVER)))
            throw err(ln, "maneuver takes " + MANEUVER);
        // correlate.md, Pack: p_enter and p_leave above 0 with a sum below 1; accel_var
        // above filter's is checked once the whole file is read.
        pk.maneuver = true;
        pk.maneuverAccelVar = dec(kv.get("accel_var"), ln);
        pk.pEnter = positive(dec(kv.get("p_enter"), ln), "p_enter", ln);
        pk.pLeave = positive(dec(kv.get("p_leave"), ln), "p_leave", ln);
        if (!(pk.pEnter + pk.pLeave < 1)) throw err(ln, "p_enter + p_leave must be below 1");
    }

    private static void restartLine(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        // correlate.md, Pack: exactly gate, above 0; valid with either method.
        Map<String, String> kv = params(tok, 1, ln);
        if (!kv.keySet().equals(new HashSet<>(RESTART))) throw err(ln, "restart takes " + RESTART);
        pk.restart = true;
        pk.restartGate = positive(dec(kv.get("gate"), ln), "restart gate", ln);
    }

    private static void staleRateLine(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        // correlate.md, Pack: exactly factor (above 0), floor_ms and ceiling_ms (integers,
        // 0 <= floor_ms <= ceiling_ms) and samples (an integer, 1 or above).
        Map<String, String> kv = params(tok, 1, ln);
        if (!kv.keySet().equals(new HashSet<>(STALE_RATE))) throw err(ln, "stale_rate takes " + STALE_RATE);
        pk.staleRate = true;
        pk.staleFactor = positive(dec(kv.get("factor"), ln), "factor", ln);
        pk.staleFloor = integer(kv.get("floor_ms"), ln);
        pk.staleCeiling = integer(kv.get("ceiling_ms"), ln);
        if (pk.staleFloor < 0 || pk.staleFloor > pk.staleCeiling)
            throw err(ln, "stale_rate needs 0 <= floor_ms <= ceiling_ms");
        pk.staleSamples = atLeastOne(integer(kv.get("samples"), ln), "samples", ln);
    }

    private static void timeDefaultLine(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        // correlate.md, Pack: the source id (a first token without '='), then error_ms,
        // state or both, each at most once; at most one line per source.
        if (tok.length < 2 || tok[1].indexOf('=') >= 0)
            throw err(ln, "time_default <source_id> error_ms=<ms> state=<state>");
        String source = tok[1];
        if (pk.timeDefault.containsKey(source)) throw err(ln, "repeated time_default " + source);
        Map<String, String> kv = params(tok, 2, ln);
        if (kv.isEmpty()) throw err(ln, "time_default needs error_ms, state or both");
        Map<String, Object> given = new LinkedHashMap<>();
        for (Map.Entry<String, String> p : kv.entrySet()) {
            if (p.getKey().equals("error_ms")) {
                given.put("error_ms", nonNegative(dec(p.getValue(), ln), "error_ms", ln));
            } else if (p.getKey().equals("state")) {
                if (!TIME_STATES.contains(p.getValue()))
                    throw err(ln, "state is coherent, drifting or free-running");
                given.put("state", p.getValue());
            } else throw err(ln, "time_default takes error_ms and state");
        }
        pk.timeDefault.put(source, given);
    }

    // ---- values, for every directive ----

    public static String one(String[] tok, int ln) throws LoadError {
        if (tok.length != 2) throw err(ln, tok[0] + " takes one value");
        return tok[1];
    }

    public static Map<String, String> params(String[] tok, int from, int ln) throws LoadError {
        Map<String, String> kv = new LinkedHashMap<>();
        for (int k = from; k < tok.length; k++) {
            int eq = tok[k].indexOf('=');
            if (eq <= 0) throw err(ln, "parameter without name=value: " + tok[k]);
            String key = tok[k].substring(0, eq);
            if (kv.put(key, tok[k].substring(eq + 1)) != null) throw err(ln, "repeated parameter " + key);
        }
        return kv;
    }

    /** A test line ({@code gate}, {@code confirm}, {@code hold}): a registered test and exactly its parameters. */
    public static Test test(CorrelatePack pk, String[] tok, int ln) throws LoadError {
        if (tok.length < 2) throw err(ln, tok[0] + " needs a test");
        TestKind kind = pk.registry.test(tok[1]);
        if (kind == null) throw err(ln, "unknown test " + tok[1]);
        List<String> want = kind.params;
        Map<String, String> kv = params(tok, 2, ln);
        if (!kv.keySet().equals(new HashSet<>(want))) throw err(ln, tok[1] + " takes " + want);
        Test t = new Test(kind);
        for (String p : want) {
            if (kind.textParams.contains(p)) {
                if (kv.get(p).isEmpty()) throw err(ln, "empty key");
                t.key = kv.get(p);
            } else t.num.put(p, dec(kv.get(p), ln));
        }
        kind.check.check(t, ln);
        return t;
    }

    public static double dec(String v, int ln) throws LoadError {
        if (!DECIMAL.matcher(v).matches()) throw err(ln, "not a number: " + v);
        return Double.parseDouble(v);
    }

    public static double positive(double v, String name, int ln) throws LoadError {
        if (!(v > 0)) throw err(ln, name + " must be above 0");
        return v;
    }

    public static double nonNegative(double v, String name, int ln) throws LoadError {
        if (!(v >= 0)) throw err(ln, name + " must be 0 or above");
        return v;
    }

    public static long atLeastOne(long v, String name, int ln) throws LoadError {
        if (v < 1) throw err(ln, name + " must be 1 or above");
        return v;
    }

    public static long integer(String v, int ln) throws LoadError {
        if (!INTEGER.matcher(v).matches()) throw err(ln, "not an integer: " + v);
        try {
            return Long.parseLong(v.startsWith("+") ? v.substring(1) : v);
        } catch (NumberFormatException e) {
            throw err(ln, "not an integer: " + v);
        }
    }
}
