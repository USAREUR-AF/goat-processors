package correlator;

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
public final class Pack {
    public static final class LoadError extends Exception {
        private static final long serialVersionUID = 1L;

        LoadError(int line, String m) {
            super("pack.def line " + line + ": " + m);
        }
        LoadError(String m) {
            super("pack.def: " + m);
        }
    }

    /** One test line: a name from the tests table and its parameters. */
    public static final class Test {
        public final String name;
        public final Map<String, Double> num = new LinkedHashMap<>();
        public String key;

        Test(String name) {
            this.name = name;
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
    public boolean sameSourceAllow = false;
    public boolean outputLatest = false;
    public final Map<String, Long> priority = new LinkedHashMap<>();
    /** Spec: Pack, `method`; false is `confirm` (correlate.md), true is `assign` (correlate-assign.md). */
    public boolean methodAssign = false;
    public double newCost, keepBonus;

    /** Spec: Tests table, the parameters of each test. */
    private static final Map<String, List<String>> TESTS = new LinkedHashMap<>();
    static {
        TESTS.put("distance", List.of("max_m"));
        TESTS.put("window", List.of("multiplier", "window_m", "err_min_m", "err_max_m"));
        TESTS.put("mahalanobis", List.of("gate"));
        TESTS.put("course", List.of("max_deg", "min_speed_ms"));
        TESTS.put("speed", List.of("max_pct", "min_speed_ms"));
        TESTS.put("altitude", List.of("max_m"));
        TESTS.put("same", List.of("key"));
    }

    private static final List<String> FILTER = List.of("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms");
    private static final Set<String> REPEATING = Set.of("gate", "confirm", "hold", "priority");
    private static final Set<String> SINGLE = Set.of("pack", "version", "method", "filter", "confirm_count",
            "hold_failures", "stale_ms", "same_source", "output", "new_cost", "keep_bonus");
    private static final List<String> REQUIRED = List.of("pack", "version", "filter", "confirm_count",
            "hold_failures", "stale_ms");
    /** Spec: correlate-assign.md, Pack. */
    private static final List<String> REQUIRED_ASSIGN = List.of("pack", "version", "method", "filter",
            "new_cost", "keep_bonus", "stale_ms");
    private static final Set<String> ONLY_CONFIRM = Set.of("confirm", "hold", "confirm_count", "hold_failures",
            "same_source", "output", "priority");
    private static final Set<String> ONLY_ASSIGN = Set.of("new_cost", "keep_bonus");
    private static final Pattern DECIMAL = Pattern.compile("[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?");
    private static final Pattern INTEGER = Pattern.compile("[+-]?[0-9]+");

    public static Pack load(Path dir) throws LoadError {
        try {
            return parse(new String(Files.readAllBytes(dir.resolve("pack.def")), StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new LoadError("cannot read " + dir + ": " + e.getMessage());
        }
    }

    public static Pack parse(String text) throws LoadError {
        Pack pk = new Pack();
        Set<String> seen = new HashSet<>();
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
            if (!REPEATING.contains(dir) && !SINGLE.contains(dir)) throw new LoadError(ln, "unknown directive " + dir);
            if (SINGLE.contains(dir) && !seen.add(dir)) throw new LoadError(ln, "repeated directive " + dir);
            firstLine.putIfAbsent(dir, ln);
            switch (dir) {
                case "pack": pk.name = one(tok, ln); break;
                case "version": pk.version = one(tok, ln); break;
                case "method": {
                    String v = one(tok, ln);
                    if (v.equals("assign")) pk.methodAssign = true;
                    else if (!v.equals("confirm")) throw new LoadError(ln, "method is confirm or assign");
                    break;
                }
                // correlate-assign.md, Pack: new_cost above 0, keep_bonus 0 or above.
                case "new_cost": pk.newCost = positive(dec(one(tok, ln), ln), "new_cost", ln); break;
                case "keep_bonus": pk.keepBonus = nonNegative(dec(one(tok, ln), ln), "keep_bonus", ln); break;
                case "filter": {
                    Map<String, String> kv = params(tok, 1, ln);
                    if (!kv.keySet().equals(new HashSet<>(FILTER))) throw new LoadError(ln, "filter takes " + FILTER);
                    // correlate.md, Pack: accel_var 0 or above, the others above 0.
                    pk.accelVar = nonNegative(dec(kv.get("accel_var"), ln), "accel_var", ln);
                    pk.defaultCe = positive(dec(kv.get("default_ce_m"), ln), "default_ce_m", ln);
                    pk.velSigma = positive(dec(kv.get("vel_sigma_ms"), ln), "vel_sigma_ms", ln);
                    pk.unknownVel = positive(dec(kv.get("unknown_vel_ms"), ln), "unknown_vel_ms", ln);
                    break;
                }
                case "gate": pk.gate.add(test(tok, ln)); break;
                case "confirm": pk.confirm.add(test(tok, ln)); break;
                case "hold": pk.hold.add(test(tok, ln)); break;
                case "confirm_count": pk.confirmCount = integer(one(tok, ln), ln); break;
                case "hold_failures": pk.holdFailures = integer(one(tok, ln), ln); break;
                case "stale_ms": pk.staleMs = integer(one(tok, ln), ln); break;
                case "same_source": {
                    String v = one(tok, ln);
                    if (v.equals("allow")) pk.sameSourceAllow = true;
                    else if (!v.equals("forbid")) throw new LoadError(ln, "same_source is forbid or allow");
                    break;
                }
                case "output": {
                    String v = one(tok, ln);
                    if (v.equals("latest")) pk.outputLatest = true;
                    else if (!v.equals("priority")) throw new LoadError(ln, "output is priority or latest");
                    break;
                }
                case "priority": {
                    if (tok.length != 3) throw new LoadError(ln, "priority <source_id> <n>");
                    if (pk.priority.containsKey(tok[1])) throw new LoadError(ln, "repeated priority " + tok[1]);
                    pk.priority.put(tok[1], integer(tok[2], ln));
                    break;
                }
                default: throw new LoadError(ln, "unknown directive " + dir);
            }
        }
        Set<String> refused = pk.methodAssign ? ONLY_CONFIRM : ONLY_ASSIGN;
        for (Map.Entry<String, Integer> d : firstLine.entrySet())
            if (refused.contains(d.getKey()))
                throw new LoadError(d.getValue(), d.getKey() + " is not a directive of method "
                        + (pk.methodAssign ? "assign" : "confirm"));
        for (String r : pk.methodAssign ? REQUIRED_ASSIGN : REQUIRED)
            if (!seen.contains(r)) throw new LoadError("missing directive " + r);
        return pk;
    }

    private static String one(String[] tok, int ln) throws LoadError {
        if (tok.length != 2) throw new LoadError(ln, tok[0] + " takes one value");
        return tok[1];
    }

    private static Map<String, String> params(String[] tok, int from, int ln) throws LoadError {
        Map<String, String> kv = new LinkedHashMap<>();
        for (int k = from; k < tok.length; k++) {
            int eq = tok[k].indexOf('=');
            if (eq <= 0) throw new LoadError(ln, "parameter without name=value: " + tok[k]);
            String key = tok[k].substring(0, eq);
            if (kv.put(key, tok[k].substring(eq + 1)) != null) throw new LoadError(ln, "repeated parameter " + key);
        }
        return kv;
    }

    private static Test test(String[] tok, int ln) throws LoadError {
        if (tok.length < 2) throw new LoadError(ln, tok[0] + " needs a test");
        List<String> want = TESTS.get(tok[1]);
        if (want == null) throw new LoadError(ln, "unknown test " + tok[1]);
        Map<String, String> kv = params(tok, 2, ln);
        if (!kv.keySet().equals(new HashSet<>(want))) throw new LoadError(ln, tok[1] + " takes " + want);
        Test t = new Test(tok[1]);
        for (String p : want) {
            if (p.equals("key")) {
                if (kv.get(p).isEmpty()) throw new LoadError(ln, "empty key");
                t.key = kv.get(p);
            } else t.num.put(p, dec(kv.get(p), ln));
        }
        return t;
    }

    private static double dec(String v, int ln) throws LoadError {
        if (!DECIMAL.matcher(v).matches()) throw new LoadError(ln, "not a number: " + v);
        return Double.parseDouble(v);
    }

    private static double positive(double v, String name, int ln) throws LoadError {
        if (!(v > 0)) throw new LoadError(ln, name + " must be above 0");
        return v;
    }

    private static double nonNegative(double v, String name, int ln) throws LoadError {
        if (!(v >= 0)) throw new LoadError(ln, name + " must be 0 or above");
        return v;
    }

    private static long integer(String v, int ln) throws LoadError {
        if (!INTEGER.matcher(v).matches()) throw new LoadError(ln, "not an integer: " + v);
        try {
            return Long.parseLong(v.startsWith("+") ? v.substring(1) : v);
        } catch (NumberFormatException e) {
            throw new LoadError(ln, "not an integer: " + v);
        }
    }
}
