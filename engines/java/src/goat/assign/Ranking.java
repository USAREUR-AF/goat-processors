package goat.assign;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * correlate-assign.md, Assignment of one source step 3, and Ranking: pure functions of a
 * source's entries.
 *
 * <p>The Ranking order is: total, then choice vector. The definition is exhaustive: every
 * assignment, in ascending choice-vector order, sorted stably by total ({@link #rankAll}).
 * {@link #rank} gives the same first k without visiting every assignment: it walks the
 * assignments in the same order, keeps the k best so far, and skips a branch only when a lower
 * bound on the total of every assignment in it is above the k-th best by more than any rounding
 * of the totals could close. Every assignment it keeps has its total computed as the definition
 * computes it. With an entry that is not finite it falls back to {@link #rankAll}.
 */
public final class Ranking {
    private Ranking() {}

    /** One assignment: its choice vector (a column index per row, or the column count for alone) and its total. */
    public static final class Ranked {
        public final int[] choice;
        public final double total;

        Ranked(int[] choice, double total) {
            this.choice = choice;
            this.total = total;
        }
    }

    /**
     * The first k assignments in the Ranking order (total, then choice vector), of rows with
     * entries {@code entry[i][j]} (null when forbidden) and alone entries {@code alone[i]}; each
     * column is chosen at most once.
     */
    public static List<Ranked> rank(Double[][] entry, double[] alone, int cols, int k) {
        int n = alone.length;
        double[] min = new double[n], maxAbs = new double[n];
        for (int i = 0; i < n; i++) {
            if (!Double.isFinite(alone[i])) return rankAll(entry, alone, cols, k);
            min[i] = alone[i];
            maxAbs[i] = Math.abs(alone[i]);
            for (int j = 0; j < cols; j++) {
                Double e = entry[i][j];
                if (e == null) continue;
                if (!Double.isFinite(e)) return rankAll(entry, alone, cols, k);
                min[i] = Math.min(min[i], e);
                maxAbs[i] = Math.max(maxAbs[i], Math.abs(e));
            }
        }
        // restMin[i], restAbs[i]: over rows i..n-1, the least value each row can take, and the
        // largest magnitude; together they bound the rest of any assignment.
        double[] restMin = new double[n + 1], restAbs = new double[n + 1];
        for (int i = n - 1; i >= 0; i--) {
            restMin[i] = restMin[i + 1] + min[i];
            restAbs[i] = restAbs[i + 1] + maxAbs[i];
        }
        Search s = new Search(entry, alone, cols, k, restMin, restAbs);
        s.walk(0, 0, 0);
        return s.best;
    }

    /** The branch-and-bound walk, in ascending choice-vector order. */
    private static final class Search {
        final Double[][] entry;
        final double[] alone, restMin, restAbs;
        final int cols, k, n;
        /** The margin per unit of magnitude: (n + 2) rounding errors, each at most 2^-53, times 8. */
        final double slack;
        final int[] choice;
        final boolean[] used;
        final List<Ranked> best = new ArrayList<>();

        Search(Double[][] entry, double[] alone, int cols, int k, double[] restMin, double[] restAbs) {
            this.entry = entry;
            this.alone = alone;
            this.cols = cols;
            this.k = k;
            this.n = alone.length;
            this.restMin = restMin;
            this.restAbs = restAbs;
            this.slack = (n + 2) * 0x1p-50;
            this.choice = new int[n];
            this.used = new boolean[cols];
        }

        /** Rows before i are chosen; their values sum to partial (in binary64) with magnitude sum partialAbs. */
        void walk(int i, double partial, double partialAbs) {
            if (k <= 0) return;
            if (best.size() == k) {
                double bound = partial + restMin[i];
                double margin = slack * (partialAbs + restAbs[i]);
                if (bound - margin > best.get(k - 1).total) return;
            }
            if (i == n) {
                keep(new Ranked(choice.clone(), total(entry, alone, cols, choice)));
                return;
            }
            for (int j = 0; j <= cols; j++) {
                if (j < cols && (used[j] || entry[i][j] == null)) continue;
                double v = j < cols ? entry[i][j] : alone[i];
                choice[i] = j;
                if (j < cols) used[j] = true;
                walk(i + 1, partial + v, partialAbs + Math.abs(v));
                if (j < cols) used[j] = false;
            }
        }

        /**
         * Inserts r after every kept assignment of a total at most its own (those come earlier
         * in the walk, so earlier in the order), then keeps the first k.
         */
        void keep(Ranked r) {
            int at = best.size();
            while (at > 0 && best.get(at - 1).total > r.total) at--;
            if (at >= k) return;
            best.add(at, r);
            if (best.size() > k) best.remove(k);
        }
    }

    /**
     * The definition: every assignment enumerated in ascending choice-vector order, then a stable
     * sort by total, then the first k.
     */
    public static List<Ranked> rankAll(Double[][] entry, double[] alone, int cols, int k) {
        List<Ranked> all = new ArrayList<>();
        enumerate(entry, alone, cols, 0, new int[alone.length], new boolean[cols], all);
        all.sort((x, y) -> x.total < y.total ? -1 : x.total > y.total ? 1 : 0);
        return all.subList(0, Math.min(k, all.size()));
    }

    private static void enumerate(Double[][] entry, double[] alone, int cols, int i, int[] choice, boolean[] used,
                                  List<Ranked> out) {
        int n = alone.length;
        if (i == n) {
            out.add(new Ranked(choice.clone(), total(entry, alone, cols, choice)));
            return;
        }
        for (int j = 0; j <= cols; j++) {
            if (j < cols && (used[j] || entry[i][j] == null)) continue;
            choice[i] = j;
            if (j < cols) used[j] = true;
            enumerate(entry, alone, cols, i + 1, choice, used, out);
            if (j < cols) used[j] = false;
        }
    }

    /** Ranking: the chosen entries taken in ascending order of value, added left to right from 0. */
    public static double total(Double[][] entry, double[] alone, int cols, int[] choice) {
        double[] v = new double[choice.length];
        for (int i = 0; i < choice.length; i++) v[i] = choice[i] < cols ? entry[i][choice[i]] : alone[i];
        Arrays.sort(v);
        double t = 0;
        for (double x : v) t += x;
        return t;
    }
}
