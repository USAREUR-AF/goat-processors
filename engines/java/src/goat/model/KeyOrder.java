package goat.model;

import java.util.Arrays;
import java.util.Comparator;

/** correlate.md, Reports: "key order" is ascending byte order; UTF-8 byte order equals code point order. */
public final class KeyOrder {
    private KeyOrder() {}

    /**
     * Code point order of two strings, without allocating. Up to the first unit where they differ
     * the strings decode to the same code points; when neither differing unit is a surrogate, those
     * units are the code points that differ, so their difference decides. A surrogate at the first
     * difference falls back to comparing the decoded code point arrays, which is the definition.
     * One string a prefix of the other: the shorter first, as in code point order.
     */
    public static final Comparator<String> KEY_ORDER = new Comparator<>() {
        @Override
        public int compare(String x, String y) {
            return KeyOrder.compare(x, y);
        }
    };

    public static int compare(String x, String y) {
        int n = Math.min(x.length(), y.length());
        for (int i = 0; i < n; i++) {
            char a = x.charAt(i), b = y.charAt(i);
            if (a == b) continue;
            if (Character.isSurrogate(a) || Character.isSurrogate(b))
                return Arrays.compare(x.codePoints().toArray(), y.codePoints().toArray());
            return a < b ? -1 : 1;
        }
        return Integer.compare(x.length(), y.length());
    }
}
