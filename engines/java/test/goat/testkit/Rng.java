package goat.testkit;

/** A seeded generator for the property and fuzz tests: xorshift64*, written here so a seed gives the same run everywhere. */
public final class Rng {
    private long s;

    public Rng(long seed) {
        s = seed == 0 ? 0x9E3779B97F4A7C15L : seed;
    }

    public long next() {
        s ^= s >>> 12;
        s ^= s << 25;
        s ^= s >>> 27;
        return s * 0x2545F4914F6CDD1DL;
    }

    /** Uniform in [0, n). */
    public int below(int n) {
        return (int) Long.remainderUnsigned(next(), n);
    }

    /** Uniform in [0, 1). */
    public double unit() {
        return (next() >>> 11) * 0x1.0p-53;
    }

    public boolean chance(double p) {
        return unit() < p;
    }

    public <T> T pick(java.util.List<T> xs) {
        return xs.get(below(xs.size()));
    }

    /** Fisher-Yates, in place. */
    public <T> void shuffle(java.util.List<T> xs) {
        for (int i = xs.size() - 1; i > 0; i--) {
            int j = below(i + 1);
            T t = xs.get(i);
            xs.set(i, xs.get(j));
            xs.set(j, t);
        }
    }
}
