package goat.trace;

import java.util.AbstractMap;
import java.util.AbstractSet;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Set;

/**
 * A JSON object: keys in insertion order, as a LinkedHashMap keeps them (a key put again keeps
 * its place), held in arrays. A key is found by comparing hashes then text along the arrays,
 * which beats hashing into buckets at an event's or a record's handful of keys; past
 * {@link #INDEXED} keys an index from key to place takes over.
 */
public final class Fields extends AbstractMap<String, Object> {
    static final int INDEXED = 16;
    private String[] keys;
    private int[] hashes;
    private Object[] values;
    private int n;
    /** Key to place, once there are more than INDEXED keys; null before. */
    private HashMap<String, Integer> index;

    public Fields() {
        this(8);
    }

    public Fields(int capacity) {
        keys = new String[Math.max(1, capacity)];
        hashes = new int[keys.length];
        values = new Object[keys.length];
    }

    private int indexOf(Object k) {
        if (!(k instanceof String)) return -1;
        if (index != null) {
            Integer i = index.get(k);
            return i == null ? -1 : i;
        }
        int h = k.hashCode();
        for (int i = 0; i < n; i++) if (hashes[i] == h && keys[i].equals(k)) return i;
        return -1;
    }

    @Override
    public Object put(String k, Object v) {
        if (k == null) throw new NullPointerException("key");
        int i = indexOf(k);
        if (i >= 0) {
            Object old = values[i];
            values[i] = v;
            return old;
        }
        if (n == keys.length) {
            keys = Arrays.copyOf(keys, n * 2);
            hashes = Arrays.copyOf(hashes, n * 2);
            values = Arrays.copyOf(values, n * 2);
        }
        keys[n] = k;
        hashes[n] = k.hashCode();
        values[n] = v;
        if (index != null) index.put(k, n);
        n++;
        if (index == null && n > INDEXED) reindex();
        return null;
    }

    @Override
    public Object get(Object k) {
        int i = indexOf(k);
        return i < 0 ? null : values[i];
    }

    @Override
    public boolean containsKey(Object k) {
        return indexOf(k) >= 0;
    }

    @Override
    public Object remove(Object k) {
        int i = indexOf(k);
        if (i < 0) return null;
        Object old = values[i];
        removeAt(i);
        return old;
    }

    private void removeAt(int i) {
        System.arraycopy(keys, i + 1, keys, i, n - i - 1);
        System.arraycopy(hashes, i + 1, hashes, i, n - i - 1);
        System.arraycopy(values, i + 1, values, i, n - i - 1);
        n--;
        keys[n] = null;
        values[n] = null;
        if (index != null) reindex();
    }

    private void reindex() {
        index = new HashMap<>(n * 2);
        for (int i = 0; i < n; i++) index.put(keys[i], i);
    }

    @Override
    public int size() {
        return n;
    }

    @Override
    public void clear() {
        Arrays.fill(keys, 0, n, null);
        Arrays.fill(values, 0, n, null);
        n = 0;
        index = null;
    }

    @Override
    public Set<Map.Entry<String, Object>> entrySet() {
        return new AbstractSet<>() {
            @Override
            public Iterator<Map.Entry<String, Object>> iterator() {
                return new Iterator<>() {
                    int next = 0;
                    int last = -1;

                    @Override
                    public boolean hasNext() {
                        return next < n;
                    }

                    @Override
                    public Map.Entry<String, Object> next() {
                        if (next >= n) throw new NoSuchElementException();
                        last = next++;
                        final int at = last;
                        final String key = keys[at];
                        return new Map.Entry<>() {
                            @Override
                            public String getKey() {
                                return key;
                            }

                            @Override
                            public Object getValue() {
                                return values[at];
                            }

                            @Override
                            public Object setValue(Object v) {
                                Object old = values[at];
                                values[at] = v;
                                return old;
                            }

                            @Override
                            public boolean equals(Object o) {
                                if (!(o instanceof Map.Entry)) return false;
                                Map.Entry<?, ?> e = (Map.Entry<?, ?>) o;
                                return key.equals(e.getKey()) && java.util.Objects.equals(values[at], e.getValue());
                            }

                            @Override
                            public int hashCode() {
                                return key.hashCode() ^ java.util.Objects.hashCode(values[at]);
                            }
                        };
                    }

                    @Override
                    public void remove() {
                        if (last < 0) throw new IllegalStateException();
                        removeAt(last);
                        next = last;
                        last = -1;
                    }
                };
            }

            @Override
            public int size() {
                return n;
            }
        };
    }
}
