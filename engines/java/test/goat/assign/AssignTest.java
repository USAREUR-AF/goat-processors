package goat.assign;

import goat.model.Axis;
import goat.testkit.Check;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/** Unit tests of the assign module: Ranking, Membership, the cost, the sensor bias math. */
public final class AssignTest {
    private AssignTest() {}

    static List<String> choices(List<Ranking.Ranked> r) {
        List<String> out = new ArrayList<>();
        for (Ranking.Ranked x : r) out.add(java.util.Arrays.toString(x.choice) + "=" + x.total);
        return out;
    }

    public static void testRankingOrder() {
        // Two rows, two columns; column 2 is the alone choice.
        Double[][] entry = {{1.0, 5.0}, {2.0, 1.0}};
        double[] alone = {9, 9};
        List<Ranking.Ranked> all = Ranking.rank(entry, alone, 2, 100);
        Check.eq(List.of("[0, 1]=2.0", "[1, 0]=7.0", "[0, 2]=10.0", "[2, 1]=10.0", "[1, 2]=14.0", "[2, 0]=11.0",
                "[2, 2]=18.0").size(), all.size(), "every assignment: 7");
        Check.eq("[0, 1]=2.0", choices(all).get(0), "least total first");
        Check.eq(List.of("[0, 1]=2.0", "[1, 0]=7.0", "[0, 2]=10.0", "[2, 1]=10.0"), choices(all).subList(0, 4),
                "equal totals: the smaller choice vector first");
        Check.eq(2, Ranking.rank(entry, alone, 2, 2).size(), "the first k");
    }

    public static void testRankingForbidden() {
        Double[][] entry = {{null}, {3.0}};
        List<Ranking.Ranked> all = Ranking.rank(entry, new double[] {4, 4}, 1, 10);
        Check.eq(List.of("[1, 0]=7.0", "[1, 1]=8.0"), choices(all), "a forbidden entry is never chosen");
    }

    public static void testTotalSortsBeforeAdding() {
        Double[][] entry = {{1e16}, {1.0}};
        double t = Ranking.total(entry, new double[] {1.0, -1e16}, 1, new int[] {0, 1});
        Check.same(-1e16 + 1e16 + 0.0, t, "ascending: -1e16 + 1e16 = 0");
        Check.same(0.0, Ranking.total(new Double[0][0], new double[0], 0, new int[0]), "no rows");
    }

    public static void testMembership() {
        Membership m = new Membership();
        TreeSet<String> s1 = new TreeSet<>(List.of("a/1", "b/1"));
        m.systems.put("s1", s1);
        m.systems.put("s2", new TreeSet<>(List.of("c/1")));
        Check.eq("s1", m.systemOf("b/1"), "systemOf");
        Check.eq(null, m.systemOf("z/9"), "none");
        Check.isTrue(m.isAlone("c/1") && !m.isAlone("a/1") && !m.isAlone("z/9"), "isAlone");
        Membership copy = m.copy();
        List<Map<String, Object>> events = new ArrayList<>();
        m.leave("c/1", "stale", events);
        Check.eq(2, events.size(), "leave, then end");
        Check.eq("end", events.get(1).get("ev"), "end");
        Check.isTrue(copy.systems.containsKey("s2"), "a copy is unchanged");
        Check.eq(List.of("s1"), List.copyOf(m.systemsMap().keySet()), "systems");
    }

    public static void testCost() {
        Axis[] own = {new Axis(0, 0, 10, 0, 1), new Axis(0, 0, 10, 0, 1)};
        Axis[] fused = {new Axis(3, 0, 5, 0, 1), new Axis(4, 0, 5, 0, 1)};
        Check.same(9.0 / 20 + 16.0 / 15, Assign.cost(own, new double[] {5, 0}, fused), "with A's timing variance");
    }

    public static void testBiasD2() {
        Bias.PairState st = Bias.PairState.initial(10);
        double d2 = Bias.d2(st, new double[] {3, 4}, new double[] {100, 100}, new double[] {0, 0}, false);
        Check.same(9.0 / 200 + 16.0 / 200, d2, "(y - 0)^2 / (s^2 + r)");
    }

    public static void testBiasAccept() {
        Bias.PairState st = Bias.PairState.initial(10);
        Bias.PairState next = Bias.accept(st, new double[] {4, 4}, new double[] {0, 0}, new double[] {8, -8}, 10, 2,
                false, 0);
        Check.eq(1L, next.n, "one pair");
        Check.same(50, next.var, "s^2 / (n + 1)");
        Check.same(8, next.o[0], "the first pair's offset is its y");
        Check.same(0.25, next.w[0], "weight 1/r");
        Check.eq(0L, st.n, "the state before is unchanged");
        Bias.PairState floor = st;
        for (int i = 0; i < 100; i++)
            floor = Bias.accept(floor, new double[] {4, 4}, new double[] {0, 0}, new double[] {8, -8}, 10, 2, false, 0);
        Check.same(4, floor.var, "var no less than f^2");
    }

    public static void testTimeOffsetFit() {
        Bias.PairState st = Bias.PairState.initial(10);
        // Objects moving east at 100 m/s, ET 20 m behind: y = -20 = o - v*tau with o = 0 gives tau = 0.2 s.
        for (int i = 0; i < 50; i++)
            st = Bias.accept(st, new double[] {1, 1}, new double[] {100, 0}, new double[] {-20, 0}, 10, 1, true, 1000);
        Check.near(200, st.tau * 1000, 5, "time offset near 200 ms (the priors pull it in a little)");
        Check.near(0, st.o[0], 1, "offset near 0");
        Check.same(st.sums[0], st.w[0], "w east is S1");
    }
}
