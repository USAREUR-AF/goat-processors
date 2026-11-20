package goat.quality;

import goat.io.LoadError;
import goat.io.PackFile;
import goat.model.Report;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** A loaded quality pack (spec/quality.md version 0.2, section Pack). */
public final class QualityPack {

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
    /**
     * Reports, "Time quality": the {@code time_default} lines, by source id. A source is in
     * {@code defaultErrorMs} when its line gives {@code error_ms}, in {@code defaultState} when
     * it gives {@code state}.
     */
    public final Map<String, Double> defaultErrorMs = new HashMap<>();
    public final Map<String, String> defaultState = new HashMap<>();

    /** The measures rules may name (quality.md, Entity measures and Source measures). */
    public final Measures measures;

    private QualityPack(Measures measures) {
        this.measures = measures;
    }

    private static final List<String> FILTER = List.of("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms");
    private static final List<String> WINDOW = List.of("window_ms", "min_samples", "forget_ms");
    private static final List<String> RULE_REQUIRED = List.of("scope", "measure", "op", "limit", "for", "clear", "action");
    private static final Set<String> RULE_ALLOWED = Set.copyOf(Arrays.asList(
            "scope", "measure", "op", "limit", "for", "clear", "action", "factor"));
    private static final Set<String> SINGLE = Set.of("pack", "version", "filter", "window");
    private static final Set<String> REPEATING = Set.of("rule", "time_default");

    // Spec: Pack, Values
    private static final Pattern NUMBER = Pattern.compile("-?[0-9]+(\\.[0-9]+)?");
    private static final Pattern INTEGER = Pattern.compile("[0-9]+");
    private static final Pattern RULE_NAME = Pattern.compile("[A-Za-z0-9._-]+");

    private static LoadError err(int line, String m) {
        return new LoadError("pack.def line " + line + ": " + m);
    }

    private static LoadError err(String m) {
        return new LoadError(m);
    }

    /** load_pack(dir): reads dir/pack.def. */
    public static QualityPack load(Path dir) throws LoadError {
        try {
            return parse(PackFile.read(dir));
        } catch (IOException e) {
            throw err("cannot read " + dir + ": " + e.getMessage());
        }
    }

    /** Parses the text of a pack.def; every error of the spec's table is a LoadError. */
    public static QualityPack parse(String text) throws LoadError {
        return parse(text, Measures.STANDARD);
    }

    /** Parses pack.def text with a table of measures. */
    public static QualityPack parse(String text, Measures measures) throws LoadError {
        QualityPack pk = new QualityPack(measures);
        Set<String> seen = new HashSet<>();
        Set<String> ruleNames = new HashSet<>();
        // Step 1: lines end at LF; a final LF does not start another line (an empty last
        // piece is an empty line, which step 4 ignores anyway).
        String[] lines = text.split("\n", -1);
        for (int n = 0; n < lines.length; n++) {
            int ln = n + 1;
            String line = lines[n];
            // Step 1: one CR at the end of a line is removed, so CRLF files load.
            if (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
            // Step 2: any control character left (a CR elsewhere included) is a load error.
            for (int c = 0; c < line.length(); c++) {
                char ch = line.charAt(c);
                if ((ch <= 0x1F && ch != '\t') || ch == 0x7F)
                    throw err(ln, String.format("control character U+%04X", (int) ch));
            }
            // Step 3: '#' starts a comment.
            int hash = line.indexOf('#');
            if (hash >= 0) line = line.substring(0, hash);
            // Steps 4 and 5: tokens separated by runs of space and tab only; an empty line is ignored.
            List<String> tok = tokens(line);
            if (tok.isEmpty()) continue;
            String dir = tok.get(0);
            List<String> vals = tok.subList(1, tok.size());
            if (!REPEATING.contains(dir) && !SINGLE.contains(dir)) throw err(ln, "unknown directive " + dir);
            if (SINGLE.contains(dir) && !seen.add(dir)) throw err(ln, "repeated directive " + dir);
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
                    if (pk.accelVar < 0) throw err(ln, "accel_var below 0");
                    if (pk.defaultCe <= 0 || pk.velSigma <= 0 || pk.unknownVel <= 0)
                        throw err(ln, "default_ce_m, vel_sigma_ms and unknown_vel_ms must be above 0");
                    break;
                }
                case "window": {
                    Map<String, String> kv = params(ln, vals, new HashSet<>(WINDOW));
                    requireAll(ln, kv, WINDOW);
                    pk.windowMs = integer(ln, kv, "window_ms");
                    pk.minSamples = integer(ln, kv, "min_samples");
                    pk.forgetMs = integer(ln, kv, "forget_ms");
                    if (pk.windowMs < 1 || pk.minSamples < 1 || pk.forgetMs < 1)
                        throw err(ln, "window values must be 1 or above");
                    break;
                }
                case "time_default":
                    timeDefault(pk, ln, vals);
                    break;
                default:
                    pk.rules.add(rule(ln, vals, ruleNames, measures));
            }
        }
        for (String d : List.of("pack", "version", "filter", "window"))
            if (!seen.contains(d)) throw err("missing directive " + d);
        return pk;
    }

    private static Rule rule(int ln, List<String> vals, Set<String> ruleNames, Measures table) throws LoadError {
        if (vals.isEmpty()) throw err(ln, "rule without a name");
        String name = vals.get(0);
        if (!RULE_NAME.matcher(name).matches()) throw err(ln, "bad rule name " + name);
        if (!ruleNames.add(name)) throw err(ln, "rule name used twice: " + name);
        Map<String, String> kv = params(ln, vals.subList(1, vals.size()), RULE_ALLOWED);
        requireAll(ln, kv, RULE_REQUIRED);

        String scope = kv.get("scope");
        if (!scope.equals("entity") && !scope.equals("source")) throw err(ln, "bad scope " + scope);
        String measure = kv.get("measure");
        List<String> measures = scope.equals("entity") ? table.entityNames() : table.sourceNames();
        if (!measures.contains(measure)) throw err(ln, "measure " + measure + " not in scope " + scope);
        String op = kv.get("op");
        if (!List.of("<", "<=", ">", ">=").contains(op)) throw err(ln, "bad op " + op);
        String action = kv.get("action");
        if (!List.of("mark", "downgrade", "drop", "alert").contains(action)) throw err(ln, "bad action " + action);

        double limit = number(ln, kv, "limit");
        double clear = number(ln, kv, "clear");
        long forN = integer(ln, kv, "for");
        if (forN < 1) throw err(ln, "for below 1");
        if (op.startsWith(">") && clear > limit) throw err(ln, "clear above limit for op " + op);
        if (op.startsWith("<") && clear < limit) throw err(ln, "clear below limit for op " + op);

        double factor = 1;
        if (action.equals("downgrade")) {
            if (!kv.containsKey("factor")) throw err(ln, "downgrade without factor");
            factor = number(ln, kv, "factor");
            if (factor < 1) throw err(ln, "factor below 1");
        } else if (kv.containsKey("factor")) {
            throw err(ln, "factor with action " + action);
        }
        return new Rule(name, scope, measure, op, limit, forN, clear, action, factor);
    }

    /**
     * {@code time_default <source_id> error_ms=<ms> state=<state>}: the grammar of correlate.md,
     * section Pack (at most once per source id, the source id first and without {@code =}, then
     * {@code error_ms}, {@code state} or both), with {@code error_ms} a number of this pack's
     * grammar (Values), 0 or above.
     */
    private static void timeDefault(QualityPack pk, int ln, List<String> vals) throws LoadError {
        if (vals.isEmpty() || vals.get(0).indexOf('=') >= 0) throw err(ln, "time_default without a source id");
        String source = vals.get(0);
        if (pk.defaultErrorMs.containsKey(source) || pk.defaultState.containsKey(source))
            throw err(ln, "time_default given twice for " + source);
        Map<String, String> kv = params(ln, vals.subList(1, vals.size()), Set.of("error_ms", "state"));
        if (kv.isEmpty()) throw err(ln, "time_default needs error_ms, state or both");
        if (kv.containsKey("error_ms")) {
            double errorMs = number(ln, kv, "error_ms");
            if (errorMs < 0) throw err(ln, "error_ms below 0");
            pk.defaultErrorMs.put(source, errorMs);
        }
        if (kv.containsKey("state")) {
            String state = kv.get("state");
            if (!Report.TIME_STATES.contains(state))
                throw err(ln, "state is coherent, drifting or free-running: " + state);
            pk.defaultState.put(source, state);
        }
    }

    /** Spec: Pack, step 5: tokens are separated by runs of space and tab, and by nothing else. */
    private static List<String> tokens(String line) {
        List<String> out = new ArrayList<>();
        for (String t : line.split("[ \t]+")) if (!t.isEmpty()) out.add(t);
        return out;
    }

    private static String single(int ln, String dir, List<String> vals) throws LoadError {
        if (vals.size() != 1) throw err(ln, dir + " takes exactly one value");
        return vals.get(0);
    }

    /** `name=value` parameters: each needs `=`, none repeated, all in `allowed`. */
    private static Map<String, String> params(int ln, List<String> vals, Set<String> allowed) throws LoadError {
        Map<String, String> kv = new LinkedHashMap<>();
        for (String t : vals) {
            int eq = t.indexOf('=');
            if (eq < 0) throw err(ln, "parameter without '=': " + t);
            String k = t.substring(0, eq);
            if (!allowed.contains(k)) throw err(ln, "unknown parameter " + k);
            if (kv.put(k, t.substring(eq + 1)) != null) throw err(ln, "repeated parameter " + k);
        }
        return kv;
    }

    private static void requireAll(int ln, Map<String, String> kv, List<String> names) throws LoadError {
        for (String k : names) if (!kv.containsKey(k)) throw err(ln, "missing parameter " + k);
    }

    private static double number(int ln, Map<String, String> kv, String k) throws LoadError {
        String v = kv.get(k);
        if (!NUMBER.matcher(v).matches()) throw err(ln, k + " is not a number: " + v);
        // Values: read as the nearest binary64; one that is infinite is a load error.
        double x = Double.parseDouble(v);
        if (Double.isInfinite(x)) throw err(ln, k + " is not finite: " + v);
        return x;
    }

    private static long integer(int ln, Map<String, String> kv, String k) throws LoadError {
        String v = kv.get(k);
        if (!INTEGER.matcher(v).matches()) throw err(ln, k + " is not an integer: " + v);
        try {
            return Long.parseLong(v);
        } catch (NumberFormatException e) {
            throw err(ln, k + " out of range: " + v);
        }
    }
}
