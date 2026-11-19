package filter;

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

/** Spec filter.md, section Pack: `load_pack` and the `pack.def` parser. */
public final class Pack {

    /** Any failure to load a pack. */
    public static final class LoadError extends Exception {
        private static final long serialVersionUID = 1L;

        LoadError(int line, String message) {
            super((line > 0 ? "line " + line + ": " : "") + message);
        }
    }

    /** A rule: a name, an action (`keep` or `drop`) and its conditions in pack order. */
    public static final class Rule {
        public final String name;
        public final String action;
        public final List<Condition> conditions = new ArrayList<>();

        Rule(String name, String action) {
            this.name = name;
            this.action = action;
        }
    }

    public String name;
    public String version;
    /** `keep` or `drop`. */
    public String defaultAction;
    public long forgetMs;
    public final List<Rule> rules = new ArrayList<>();

    /** load_pack(dir): reads `dir/pack.def`. */
    public static Pack load(Path dir) throws LoadError {
        try {
            return parse(new String(Files.readAllBytes(dir.resolve("pack.def")), StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new LoadError(0, "cannot read pack.def: " + e.getMessage());
        }
    }

    /** Parses the text of a `pack.def`. */
    public static Pack parse(String text) throws LoadError {
        Pack p = new Pack();
        Set<String> seen = new HashSet<>();
        Set<String> ruleNames = new HashSet<>();
        Rule current = null;
        String[] lines = text.split("\n", -1);
        for (int n = 0; n < lines.length; n++) {
            int lineNo = n + 1;
            String line = lines[n];
            int hash = line.indexOf('#');                         // `#` starts a comment
            if (hash >= 0) line = line.substring(0, hash);
            line = line.strip();
            if (line.isEmpty()) continue;                         // blank lines are ignored
            String[] tok = line.split("[ \t]+");                  // separated by spaces or tabs
            String directive = tok[0];
            int nargs = tok.length - 1;

            switch (directive) {
                case "pack":
                case "version":
                case "default":
                case "forget_ms": {
                    if (!seen.add(directive)) throw new LoadError(lineNo, "repeated " + directive);
                    if (nargs != 1) throw new LoadError(lineNo, directive + " takes one argument");
                    String arg = tok[1];
                    if (directive.equals("pack")) p.name = arg;
                    else if (directive.equals("version")) p.version = arg;
                    else if (directive.equals("default")) p.defaultAction = action(lineNo, arg);
                    else p.forgetMs = integerAbove0(lineNo, "forget_ms", arg);
                    break;
                }
                case "rule": {
                    if (nargs != 2) throw new LoadError(lineNo, "rule takes a name and an action");
                    String name = tok[1];
                    if (name.equals("default")) throw new LoadError(lineNo, "a rule cannot be named default");
                    if (!ruleNames.add(name)) throw new LoadError(lineNo, "repeated rule " + name);
                    if (current != null && current.conditions.isEmpty())
                        throw new LoadError(lineNo, "rule " + current.name + " has no when line");
                    current = new Rule(name, action(lineNo, tok[2]));
                    p.rules.add(current);
                    break;
                }
                case "when": {
                    if (current == null) throw new LoadError(lineNo, "when before the first rule");
                    current.conditions.add(when(lineNo, tok));
                    break;
                }
                default:
                    throw new LoadError(lineNo, "unknown directive " + directive);
            }
        }
        if (current != null && current.conditions.isEmpty())
            throw new LoadError(0, "rule " + current.name + " has no when line");
        for (String d : new String[] {"pack", "version", "default", "forget_ms"})
            if (!seen.contains(d)) throw new LoadError(0, "missing " + d);
        return p;
    }

    private static String action(int lineNo, String a) throws LoadError {
        if (a.equals("keep") || a.equals("drop")) return a;
        throw new LoadError(lineNo, "action must be keep or drop: " + a);
    }

    // ---- when lines ----

    /** Parameter sets, exactly (table "Parameter sets"). */
    private static final Map<String, List<Set<String>>> PARAMETER_SETS = new LinkedHashMap<>();

    static {
        PARAMETER_SETS.put("circle", List.of(Set.of("lat", "lon", "radius_m")));
        PARAMETER_SETS.put("polygon", List.of(Set.of("vertices")));
        PARAMETER_SETS.put("near", List.of(Set.of("reference", "radius_m", "max_age_ms")));
        for (String c : new String[] {"env", "affiliation", "source", "uid"})
            PARAMETER_SETS.put(c, List.of(Set.of("in")));
        PARAMETER_SETS.put("key", List.of(Set.of("name", "eq"), Set.of("name", "in"),
                Set.of("name", "min"), Set.of("name", "max"), Set.of("name", "min", "max")));
        PARAMETER_SETS.put("has", List.of(Set.of("name")));
        for (String c : new String[] {"speed", "altitude"})
            PARAMETER_SETS.put(c, List.of(Set.of("min"), Set.of("max"), Set.of("min", "max")));
        PARAMETER_SETS.put("interval", List.of(Set.of("min_ms")));
        PARAMETER_SETS.put("order", List.of(Set.of()));
    }

    /** `when [not] <condition> <param>=<value> ...`; tok[0] is `when`. */
    private static Condition when(int lineNo, String[] tok) throws LoadError {
        int i = 1;
        boolean negated = false;
        if (i < tok.length && tok[i].equals("not")) {
            negated = true;
            i++;
        }
        if (i >= tok.length) throw new LoadError(lineNo, "when without a condition");
        String test = tok[i++];
        List<Set<String>> sets = PARAMETER_SETS.get(test);
        if (sets == null) throw new LoadError(lineNo, "unknown condition " + test);

        // The name is the text before the first `=` and the value is the rest.
        Map<String, String> params = new LinkedHashMap<>();
        for (; i < tok.length; i++) {
            int eq = tok[i].indexOf('=');
            if (eq < 0) throw new LoadError(lineNo, "parameter without '=': " + tok[i]);
            String name = tok[i].substring(0, eq);
            if (params.put(name, tok[i].substring(eq + 1)) != null)
                throw new LoadError(lineNo, "parameter given twice: " + name);
        }
        if (!sets.contains(params.keySet()))
            throw new LoadError(lineNo, test + " does not take parameters " + params.keySet());

        Condition c = new Condition(test, negated);
        for (Map.Entry<String, String> e : params.entrySet()) {
            String v = e.getValue();
            switch (e.getKey()) {
                case "lat": c.lat = latitude(lineNo, v); break;
                case "lon": c.lon = longitude(lineNo, v); break;
                case "radius_m":
                    c.radiusM = number(lineNo, "radius_m", v);
                    if (c.radiusM < 0) throw new LoadError(lineNo, "radius_m below 0");
                    break;
                case "min": c.min = number(lineNo, "min", v); break;
                case "max": c.max = number(lineNo, "max", v); break;
                case "max_age_ms": c.maxAgeMs = integer(lineNo, "max_age_ms", v); break;
                case "min_ms": c.minMs = integerAbove0(lineNo, "min_ms", v); break;
                case "vertices": vertices(lineNo, v, c); break;
                case "in": c.in = list(lineNo, v); break;
                case "reference": c.reference = token(lineNo, "reference", v); break;
                case "name": c.name = token(lineNo, "name", v); break;
                case "eq": c.eq = token(lineNo, "eq", v); break;
                default: throw new AssertionError(e.getKey());
            }
        }
        if (c.min != null && c.max != null && c.min > c.max)
            throw new LoadError(lineNo, "min above max");
        return c;
    }

    // ---- values (table "Values") ----

    private static final Pattern NUMBER = Pattern.compile("-?[0-9]+(\\.[0-9]+)?");
    private static final Pattern INTEGER = Pattern.compile("[0-9]+");

    /** True when t matches the number grammar `-?[0-9]+(\.[0-9]+)?`. */
    static boolean isNumber(String t) {
        return NUMBER.matcher(t).matches();
    }

    /** A number, read as the nearest binary64. */
    private static double number(int lineNo, String what, String t) throws LoadError {
        if (!isNumber(t)) throw new LoadError(lineNo, what + " is not a number: " + t);
        return Double.parseDouble(t);
    }

    private static double latitude(int lineNo, String t) throws LoadError {
        double v = number(lineNo, "lat", t);
        if (v < -90 || v > 90) throw new LoadError(lineNo, "lat out of range: " + t);
        return v;
    }

    private static double longitude(int lineNo, String t) throws LoadError {
        double v = number(lineNo, "lon", t);
        if (v < -180 || v > 180) throw new LoadError(lineNo, "lon out of range: " + t);
        return v;
    }

    /** An integer `[0-9]+`, at most 9223372036854775807. */
    private static long integer(int lineNo, String what, String t) throws LoadError {
        if (!INTEGER.matcher(t).matches()) throw new LoadError(lineNo, what + " is not an integer: " + t);
        try {
            return Long.parseLong(t);
        } catch (NumberFormatException e) {
            throw new LoadError(lineNo, what + " above 9223372036854775807");
        }
    }

    private static long integerAbove0(int lineNo, String what, String t) throws LoadError {
        long v = integer(lineNo, what, t);
        if (v <= 0) throw new LoadError(lineNo, what + " must be above 0");
        return v;
    }

    /** `<lat>,<lon>;<lat>,<lon>;...` with at least three pairs. */
    private static void vertices(int lineNo, String t, Condition c) throws LoadError {
        String[] pairs = t.split(";", -1);
        if (pairs.length < 3) throw new LoadError(lineNo, "a polygon needs at least three vertices");
        c.vertexLat = new double[pairs.length];
        c.vertexLon = new double[pairs.length];
        for (int k = 0; k < pairs.length; k++) {
            String[] ll = pairs[k].split(",", -1);
            if (ll.length != 2) throw new LoadError(lineNo, "bad vertex: " + pairs[k]);
            c.vertexLat[k] = latitude(lineNo, ll[0]);
            c.vertexLon[k] = longitude(lineNo, ll[1]);
        }
    }

    /** One or more non-empty items separated by `,`. */
    private static List<String> list(int lineNo, String t) throws LoadError {
        List<String> items = List.of(t.split(",", -1));
        for (String s : items) if (s.isEmpty()) throw new LoadError(lineNo, "empty list item in: " + t);
        return items;
    }

    /** A non-empty token. */
    private static String token(int lineNo, String what, String t) throws LoadError {
        if (t.isEmpty()) throw new LoadError(lineNo, what + " is empty");
        return t;
    }
}
