package goat.fuse;

import goat.io.LoadError;
import goat.io.PackFile;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** A loaded fuse pack (spec/fuse.md, Pack). */
public final class FusePack {

    /** One `attribute <key> rule=<rule>` line. */
    public static final class Attribute {
        public final String key, rule;

        Attribute(String key, String rule) {
            this.key = key;
            this.rule = rule;
        }
    }

    /** The kinematics methods, in the order of fuse.md (the table of {@link Kinematics}). */
    public static final List<String> METHODS = List.copyOf(Kinematics.TABLE.keySet());
    public static final List<String> RULES = List.of("priority", "latest", "majority", "max", "min");

    public String name, version;
    public double accelVar, defaultCe, velSigma, unknownVel;
    public String kinematics;
    public long staleMs;
    /** Attribute lines in pack order. */
    public final List<Attribute> attributes = new ArrayList<>();
    /** Source lines; the index is the source's rank (Kinematics, Rank). */
    public final List<String> sources = new ArrayList<>();

    private static final List<String> FILTER = List.of("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms");
    private static final Set<String> ONCE = Set.of("pack", "version", "filter", "kinematics", "stale_ms");
    private static final Set<String> REPEATING = Set.of("attribute", "source");

    /** Pack: a number is an optional `-`, digits, optionally `.` digits, optionally an exponent. */
    private static final Pattern NUMBER = Pattern.compile("-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?");
    /** Pack: an integer is one or more digits. */
    private static final Pattern INTEGER = Pattern.compile("[0-9]+");

    private static LoadError err(int line, String m) {
        return new LoadError("pack.def line " + line + ": " + m);
    }

    private static LoadError err(String m) {
        return new LoadError("pack.def: " + m);
    }

    public static FusePack load(Path dir) throws LoadError {
        try {
            return parse(PackFile.read(dir));
        } catch (IOException e) {
            throw err("cannot read " + dir + ": " + e.getMessage());
        }
    }

    public static FusePack parse(String text) throws LoadError {
        FusePack pk = new FusePack();
        Set<String> seen = new HashSet<>();
        String[] lines = text.split("\n", -1);
        for (int n = 0; n < lines.length; n++) {
            int ln = n + 1;
            List<String> tok = tokens(lines[n]);
            if (tok.isEmpty()) continue;
            String dir = tok.get(0);
            if (!ONCE.contains(dir) && !REPEATING.contains(dir)) throw err(ln, "unknown directive " + dir);
            if (ONCE.contains(dir) && !seen.add(dir)) throw err(ln, "repeated directive " + dir);
            switch (dir) {
                case "pack": pk.name = one(tok, ln); break;
                case "version": pk.version = one(tok, ln); break;
                case "filter": filter(pk, tok, ln); break;
                case "kinematics": {
                    String m = one(tok, ln);
                    if (!METHODS.contains(m)) throw err(ln, "kinematics is one of " + METHODS);
                    pk.kinematics = m;
                    break;
                }
                case "stale_ms": {
                    String v = one(tok, ln);
                    if (!INTEGER.matcher(v).matches()) throw err(ln, "stale_ms is an integer: " + v);
                    try {
                        pk.staleMs = Long.parseLong(v);
                    } catch (NumberFormatException e) {
                        throw err(ln, "stale_ms out of range: " + v);
                    }
                    break;
                }
                case "attribute": attribute(pk, tok, ln); break;
                case "source": {
                    String s = one(tok, ln);
                    if (pk.sources.contains(s)) throw err(ln, "repeated source " + s);
                    pk.sources.add(s);
                    break;
                }
                default: throw err(ln, "unknown directive " + dir);
            }
        }
        for (String d : List.of("pack", "version", "filter", "kinematics", "stale_ms"))
            if (!seen.contains(d)) throw err("missing directive " + d);
        return pk;
    }

    /**
     * Pack: a CR at the end of a line is removed, `#` starts a comment, and the line is split
     * on runs of spaces and tabs (only those two characters).
     */
    private static List<String> tokens(String line) {
        if (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
        int hash = line.indexOf('#');
        if (hash >= 0) line = line.substring(0, hash);
        List<String> tok = new ArrayList<>();
        for (String t : line.split("[ \t]+")) if (!t.isEmpty()) tok.add(t);
        return tok;
    }

    private static String one(List<String> tok, int ln) throws LoadError {
        if (tok.size() != 2) throw err(ln, tok.get(0) + " takes one value");
        return tok.get(1);
    }

    /** `filter`: exactly the four parameters, each name=value, each a number, within its bounds. */
    private static void filter(FusePack pk, List<String> tok, int ln) throws LoadError {
        Map<String, String> kv = new LinkedHashMap<>();
        for (String t : tok.subList(1, tok.size())) {
            int eq = t.indexOf('=');
            if (eq < 0) throw err(ln, "parameter without '=': " + t);
            String name = t.substring(0, eq);
            if (!FILTER.contains(name)) throw err(ln, "unknown filter parameter " + name);
            if (kv.put(name, t.substring(eq + 1)) != null) throw err(ln, "repeated parameter " + name);
        }
        for (String name : FILTER) if (!kv.containsKey(name)) throw err(ln, "missing parameter " + name);
        pk.accelVar = number(kv.get("accel_var"), ln);
        pk.defaultCe = number(kv.get("default_ce_m"), ln);
        pk.velSigma = number(kv.get("vel_sigma_ms"), ln);
        pk.unknownVel = number(kv.get("unknown_vel_ms"), ln);
        if (!(pk.accelVar >= 0)) throw err(ln, "accel_var must be 0 or above");
        if (!(pk.defaultCe > 0)) throw err(ln, "default_ce_m must be above 0");
        if (!(pk.velSigma > 0)) throw err(ln, "vel_sigma_ms must be above 0");
        if (!(pk.unknownVel > 0)) throw err(ln, "unknown_vel_ms must be above 0");
    }

    /** `attribute <key> rule=<rule>`: a key without `=`, used once, then exactly rule=<rule>. */
    private static void attribute(FusePack pk, List<String> tok, int ln) throws LoadError {
        if (tok.size() != 3) throw err(ln, "attribute <key> rule=<rule>");
        String key = tok.get(1), param = tok.get(2);
        if (key.indexOf('=') >= 0) throw err(ln, "attribute key holds '=': " + key);
        if (!param.startsWith("rule=")) throw err(ln, "attribute takes rule=<rule>");
        String rule = param.substring("rule=".length());
        if (!RULES.contains(rule)) throw err(ln, "rule is one of " + RULES);
        for (Attribute a : pk.attributes)
            if (a.key.equals(key)) throw err(ln, "repeated attribute " + key);
        pk.attributes.add(new Attribute(key, rule));
    }

    private static double number(String v, int ln) throws LoadError {
        if (!NUMBER.matcher(v).matches()) throw err(ln, "not a number: " + v);
        return Double.parseDouble(v);
    }
}
