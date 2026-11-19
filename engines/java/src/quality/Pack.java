package quality;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** A loaded quality pack (spec/quality.md, section Pack). */
public final class Pack {

    /** A pack that does not load. */
    public static final class LoadError extends Exception {
        private static final long serialVersionUID = 1L;

        LoadError(int line, String m) {
            super("pack.def line " + line + ": " + m);
        }

        LoadError(String m) {
            super(m);
        }
    }

    /** One `rule` line (spec: Rules). */
    public static final class Rule {
        public final String name, scope, measure, op, action;
        public final double limit, clear;
        public final long forN;
        /** The downgrade factor; 1 for any other action (never used then). */
        public final double factor;

        Rule(String name, String scope, String measure, String op, double limit, long forN,
             double clear, String action, double factor) {
            this.name = name; this.scope = scope; this.measure = measure; this.op = op;
            this.limit = limit; this.forN = forN; this.clear = clear; this.action = action;
            this.factor = factor;
        }

        /** "v op limit" (spec: Rules, Evaluation, not active). */
        boolean meets(double v) {
            switch (op) {
                case "<": return v < limit;
                case "<=": return v <= limit;
                case ">": return v > limit;
                default: return v >= limit;
            }
        }

        /** The clear test (spec: Rules, Evaluation, active). */
        boolean clears(double v) {
            return op.startsWith(">") ? v < clear : v > clear;
        }
    }

    public String name, version;
    // filter
    public double accelVar, defaultCe, velSigma, unknownVel;
    // window
    public long windowMs, minSamples, forgetMs;
    /** Rules in pack order. */
    public final List<Rule> rules = new ArrayList<>();

    /** Spec: Entity measures, the table's measures in table order. */
    public static final List<String> ENTITY_MEASURES = List.of(
            "reports", "interval_last", "interval_mean", "interval_max", "age",
            "latency_mean", "latency_max", "nis_mean", "speed_err_mean",
            "out_of_order", "duplicate", "missing_ce", "missing_vel", "missing_hae");

    /** Spec: Source measures, the entity measures plus `entities`. */
    public static final List<String> SOURCE_MEASURES;

    static {
        List<String> s = new ArrayList<>(ENTITY_MEASURES);
        s.add("entities");
        SOURCE_MEASURES = List.copyOf(s);
    }

    private static final List<String> FILTER = List.of("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms");
    private static final List<String> WINDOW = List.of("window_ms", "min_samples", "forget_ms");
    private static final List<String> RULE_REQUIRED = List.of("scope", "measure", "op", "limit", "for", "clear", "action");
    private static final Set<String> RULE_ALLOWED = new HashSet<>(Arrays.asList(
            "scope", "measure", "op", "limit", "for", "clear", "action", "factor"));
    private static final Set<String> SINGLE = Set.of("pack", "version", "filter", "window");

    // Spec: Pack, Values
    private static final Pattern NUMBER = Pattern.compile("-?[0-9]+(\\.[0-9]+)?");
    private static final Pattern INTEGER = Pattern.compile("[0-9]+");
    private static final Pattern RULE_NAME = Pattern.compile("[A-Za-z0-9._-]+");

    /** load_pack(dir): reads dir/pack.def. */
    public static Pack load(Path dir) throws LoadError {
        try {
            return parse(new String(Files.readAllBytes(dir.resolve("pack.def")), StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new LoadError("cannot read " + dir + ": " + e.getMessage());
        }
    }

    /** Parses the text of a pack.def; every error of the spec's table is a LoadError. */
    public static Pack parse(String text) throws LoadError {
        Pack pk = new Pack();
        Set<String> seen = new HashSet<>();
        Set<String> ruleNames = new HashSet<>();
        String[] lines = text.split("\n", -1);
        for (int n = 0; n < lines.length; n++) {
            int ln = n + 1;
            String line = lines[n];
            int hash = line.indexOf('#');
            if (hash >= 0) line = line.substring(0, hash);
            List<String> tok = tokens(line);
            if (tok.isEmpty()) continue;
            String dir = tok.get(0);
            List<String> vals = tok.subList(1, tok.size());
            if (!dir.equals("rule") && !SINGLE.contains(dir)) throw new LoadError(ln, "unknown directive " + dir);
            if (SINGLE.contains(dir) && !seen.add(dir)) throw new LoadError(ln, "repeated directive " + dir);
            switch (dir) {
                case "pack":
                    pk.name = single(ln, dir, vals);
                    break;
                case "version":
                    pk.version = single(ln, dir, vals);
                    break;
                case "filter": {
                    Map<String, String> kv = params(ln, vals, new HashSet<>(FILTER));
                    requireAll(ln, kv, FILTER);
                    pk.accelVar = number(ln, kv, "accel_var");
                    pk.defaultCe = number(ln, kv, "default_ce_m");
                    pk.velSigma = number(ln, kv, "vel_sigma_ms");
                    pk.unknownVel = number(ln, kv, "unknown_vel_ms");
                    if (pk.accelVar < 0) throw new LoadError(ln, "accel_var below 0");
                    if (pk.defaultCe <= 0 || pk.velSigma <= 0 || pk.unknownVel <= 0)
                        throw new LoadError(ln, "default_ce_m, vel_sigma_ms and unknown_vel_ms must be above 0");
                    break;
                }
                case "window": {
                    Map<String, String> kv = params(ln, vals, new HashSet<>(WINDOW));
                    requireAll(ln, kv, WINDOW);
                    pk.windowMs = integer(ln, kv, "window_ms");
                    pk.minSamples = integer(ln, kv, "min_samples");
                    pk.forgetMs = integer(ln, kv, "forget_ms");
                    if (pk.windowMs < 1 || pk.minSamples < 1 || pk.forgetMs < 1)
                        throw new LoadError(ln, "window values must be 1 or above");
                    break;
                }
                default:
                    pk.rules.add(rule(ln, vals, ruleNames));
            }
        }
        for (String d : List.of("pack", "version", "filter", "window"))
            if (!seen.contains(d)) throw new LoadError("missing directive " + d);
        return pk;
    }

    private static Rule rule(int ln, List<String> vals, Set<String> ruleNames) throws LoadError {
        if (vals.isEmpty()) throw new LoadError(ln, "rule without a name");
        String name = vals.get(0);
        if (!RULE_NAME.matcher(name).matches()) throw new LoadError(ln, "bad rule name " + name);
        if (!ruleNames.add(name)) throw new LoadError(ln, "rule name used twice: " + name);
        Map<String, String> kv = params(ln, vals.subList(1, vals.size()), RULE_ALLOWED);
        requireAll(ln, kv, RULE_REQUIRED);

        String scope = kv.get("scope");
        if (!scope.equals("entity") && !scope.equals("source")) throw new LoadError(ln, "bad scope " + scope);
        String measure = kv.get("measure");
        List<String> measures = scope.equals("entity") ? ENTITY_MEASURES : SOURCE_MEASURES;
        if (!measures.contains(measure)) throw new LoadError(ln, "measure " + measure + " not in scope " + scope);
        String op = kv.get("op");
        if (!List.of("<", "<=", ">", ">=").contains(op)) throw new LoadError(ln, "bad op " + op);
        String action = kv.get("action");
        if (!List.of("mark", "downgrade", "drop", "alert").contains(action)) throw new LoadError(ln, "bad action " + action);

        double limit = number(ln, kv, "limit");
        double clear = number(ln, kv, "clear");
        long forN = integer(ln, kv, "for");
        if (forN < 1) throw new LoadError(ln, "for below 1");
        if (op.startsWith(">") && clear > limit) throw new LoadError(ln, "clear above limit for op " + op);
        if (op.startsWith("<") && clear < limit) throw new LoadError(ln, "clear below limit for op " + op);

        double factor = 1;
        if (action.equals("downgrade")) {
            if (!kv.containsKey("factor")) throw new LoadError(ln, "downgrade without factor");
            factor = number(ln, kv, "factor");
            if (factor < 1) throw new LoadError(ln, "factor below 1");
        } else if (kv.containsKey("factor")) {
            throw new LoadError(ln, "factor with action " + action);
        }
        return new Rule(name, scope, measure, op, limit, forN, clear, action, factor);
    }

    /** Spec: Pack, tokens are separated by spaces or tabs. */
    private static List<String> tokens(String line) {
        List<String> out = new ArrayList<>();
        for (String t : line.split("[ \t]+")) if (!t.isEmpty()) out.add(t);
        return out;
    }

    private static String single(int ln, String dir, List<String> vals) throws LoadError {
        if (vals.size() != 1) throw new LoadError(ln, dir + " takes exactly one value");
        return vals.get(0);
    }

    /** `name=value` parameters: each needs `=`, none repeated, all in `allowed`. */
    private static Map<String, String> params(int ln, List<String> vals, Set<String> allowed) throws LoadError {
        Map<String, String> kv = new LinkedHashMap<>();
        for (String t : vals) {
            int eq = t.indexOf('=');
            if (eq < 0) throw new LoadError(ln, "parameter without '=': " + t);
            String k = t.substring(0, eq);
            if (!allowed.contains(k)) throw new LoadError(ln, "unknown parameter " + k);
            if (kv.put(k, t.substring(eq + 1)) != null) throw new LoadError(ln, "repeated parameter " + k);
        }
        return kv;
    }

    private static void requireAll(int ln, Map<String, String> kv, List<String> names) throws LoadError {
        for (String k : names) if (!kv.containsKey(k)) throw new LoadError(ln, "missing parameter " + k);
    }

    private static double number(int ln, Map<String, String> kv, String k) throws LoadError {
        String v = kv.get(k);
        if (!NUMBER.matcher(v).matches()) throw new LoadError(ln, k + " is not a number: " + v);
        return Double.parseDouble(v);
    }

    private static long integer(int ln, Map<String, String> kv, String k) throws LoadError {
        String v = kv.get(k);
        if (!INTEGER.matcher(v).matches()) throw new LoadError(ln, k + " is not an integer: " + v);
        try {
            return Long.parseLong(v);
        } catch (NumberFormatException e) {
            throw new LoadError(ln, k + " out of range: " + v);
        }
    }
}
