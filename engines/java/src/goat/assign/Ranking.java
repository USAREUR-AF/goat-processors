package goat.assign;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * correlate-assign.md, Assignment of one source step 3, and Ranking: pure functions of a
 * source's entries.
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
     * column is chosen at most once. Every assignment is enumerated in ascending choice-vector
     * order, then sorted stably by total.
     */
    public static List<Ranked> rank(Double[][] entry, double[] alone, int cols, int k) {
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
