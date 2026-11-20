package goat.io;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON reader and writer. Objects are LinkedHashMap, arrays ArrayList,
 * integers Long, other numbers Double, JSON null is Java null. Input that is not JSON is an
 * IllegalArgumentException, whatever is wrong with it.
 */
public final class Json {
    private final String s;
    private int i;

    private Json(String s) {
        this.s = s;
    }

    public static Object parse(String text) {
        Json p = new Json(text);
        p.ws();
        Object v = p.value();
        p.ws();
        if (p.i != p.s.length()) throw p.err("trailing data");
        return v;
    }

    private RuntimeException err(String m) {
        return new IllegalArgumentException("json: " + m + " at " + i);
    }

    private void ws() {
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++;
            else break;
        }
    }

    /** The character at the cursor; the end of the input is an error. */
    private char peek() {
        if (i >= s.length()) throw err("unexpected end");
        return s.charAt(i);
    }

    private void expect(char c) {
        if (i >= s.length() || s.charAt(i) != c) throw err("expected '" + c + "'");
        i++;
    }

    private Object value() {
        if (i >= s.length()) throw err("unexpected end");
        char c = s.charAt(i);
        switch (c) {
            case '{': return object();
            case '[': return array();
            case '"': return string();
            case 't': word("true"); return Boolean.TRUE;
            case 'f': word("false"); return Boolean.FALSE;
            case 'n': word("null"); return null;
            default: return number();
        }
    }

    private void word(String w) {
        if (!s.startsWith(w, i)) throw err("bad literal");
        i += w.length();
    }

    private Map<String, Object> object() {
        Map<String, Object> m = new LinkedHashMap<>();
        expect('{');
        ws();
        if (peek() == '}') { i++; return m; }
        while (true) {
            ws();
            String k = string();
            ws();
            expect(':');
            ws();
            m.put(k, value());
            ws();
            if (peek() == ',') { i++; continue; }
            expect('}');
            return m;
        }
    }

    private List<Object> array() {
        List<Object> l = new ArrayList<>();
        expect('[');
        ws();
        if (peek() == ']') { i++; return l; }
        while (true) {
            ws();
            l.add(value());
            ws();
            if (peek() == ',') { i++; continue; }
            expect(']');
            return l;
        }
    }

    private String string() {
        expect('"');
        StringBuilder b = new StringBuilder();
        while (true) {
            if (i >= s.length()) throw err("unterminated string");
            char c = s.charAt(i++);
            if (c == '"') return b.toString();
            if (c != '\\') { b.append(c); continue; }
            char e = peek();
            i++;
            switch (e) {
                case '"': b.append('"'); break;
                case '\\': b.append('\\'); break;
                case '/': b.append('/'); break;
                case 'b': b.append('\b'); break;
                case 'f': b.append('\f'); break;
                case 'n': b.append('\n'); break;
                case 'r': b.append('\r'); break;
                case 't': b.append('\t'); break;
                case 'u':
                    if (i + 4 > s.length()) throw err("unexpected end");
                    try {
                        b.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                    } catch (NumberFormatException ex) {
                        throw err("bad escape");
                    }
                    i += 4;
                    break;
                default: throw err("bad escape");
            }
        }
    }

    private Object number() {
        int start = i;
        boolean integral = true;
        if (s.charAt(i) == '-') i++;
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c >= '0' && c <= '9') i++;
            else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { integral = false; i++; }
            else break;
        }
        String t = s.substring(start, i);
        if (t.isEmpty() || t.equals("-")) throw err("bad value");
        if (integral) {
            try { return Long.parseLong(t); } catch (NumberFormatException ex) { return Double.parseDouble(t); }
        }
        return Double.parseDouble(t);
    }

    public static String write(Object v) {
        StringBuilder b = new StringBuilder();
        write(b, v);
        return b.toString();
    }

    private static void write(StringBuilder b, Object v) {
        if (v == null) b.append("null");
        else if (v instanceof String) quote(b, (String) v);
        else if (v instanceof Map) {
            b.append('{');
            Iterator<? extends Map.Entry<?, ?>> it = ((Map<?, ?>) v).entrySet().iterator();
            while (it.hasNext()) {
                Map.Entry<?, ?> e = it.next();
                quote(b, (String) e.getKey());
                b.append(':');
                write(b, e.getValue());
                if (it.hasNext()) b.append(',');
            }
            b.append('}');
        } else if (v instanceof List) {
            b.append('[');
            List<?> l = (List<?>) v;
            for (int k = 0; k < l.size(); k++) {
                if (k > 0) b.append(',');
                write(b, l.get(k));
            }
            b.append(']');
        } else b.append(v);
    }

    private static void quote(StringBuilder b, String s) {
        b.append('"');
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        b.append('"');
    }
}
