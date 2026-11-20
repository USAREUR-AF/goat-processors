package goat.model;

import java.util.Arrays;
import java.util.Comparator;

/** correlate.md, Reports: "key order" is ascending byte order; UTF-8 byte order equals code point order. */
public final class KeyOrder {
    private KeyOrder() {}

    public static final Comparator<String> KEY_ORDER = (x, y) -> Arrays.compare(
            x.codePoints().toArray(), y.codePoints().toArray());
}
