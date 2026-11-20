// Unit tests of src/assign: ranking, memberships, cost, bias.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <functional>
#include <limits>
#include <string>

#include "assign/bias.hpp"
#include "assign/cost.hpp"
#include "assign/membership.hpp"
#include "assign/ranking.hpp"
#include "check.hpp"
#include "random.hpp"

using corr::Json;
namespace cc = corr::correlate;

namespace {
const double INF = std::numeric_limits<double>::infinity();
}

TEST(assign, ranking_orders_by_total_then_choice) {
    // Two rows, one column: entries[i][1] is alone.
    std::vector<std::vector<double>> entries = {{1, 5}, {2, 5}};
    auto r = cc::rank_assignments(entries, 1, 10);
    CHECK_EQ(r.size(), size_t{3});   // (0,alone) (alone,0) (alone,alone)
    CHECK_EQ(r[0].total, 6.0);
    CHECK(r[0].choice == std::vector<size_t>({0, 1}));
    CHECK_EQ(r[1].total, 7.0);
    CHECK_EQ(r[2].total, 10.0);
    auto top = cc::rank_assignments(entries, 1, 1);
    CHECK_EQ(top.size(), size_t{1});
    CHECK(top[0].choice == r[0].choice);
}

TEST(assign, ranking_ties_and_forbidden) {
    std::vector<std::vector<double>> entries = {{3, 3, INF}, {3, 3, INF}};
    auto r = cc::rank_assignments(entries, 2, 5);
    CHECK_EQ(r.size(), size_t{2});   // each row must take a column, one each
    CHECK(r[0].choice == std::vector<size_t>({0, 1}));
    CHECK(r[1].choice == std::vector<size_t>({1, 0}));
    std::vector<std::vector<double>> none = {{INF, INF}};
    CHECK(cc::rank_assignments(none, 1, 3).empty());
    // The total adds the chosen entries in ascending order: (1e16 + 1) + 1 differs from 1e16 + (1 + 1).
    std::vector<std::vector<double>> order = {{1e16, INF, INF, INF}, {INF, 1, INF, INF}, {INF, INF, 1, INF}};
    auto t = cc::rank_assignments(order, 3, 1);
    CHECK_EQ(t[0].total, (1.0 + 1.0) + 1e16);
}

TEST(assign, ranking_matches_exhaustive_count) {
    // n rows, c columns, every entry allowed: the number of assignments is
    // sum over k of C(n,k) * c!/(c-k)!.
    std::vector<std::vector<double>> entries(3, std::vector<double>(4, 1.0));
    auto r = cc::rank_assignments(entries, 3, 1000);
    CHECK_EQ(r.size(), size_t{1 + 9 + 18 + 6});
    for (size_t i = 1; i < r.size(); ++i)
        CHECK(r[i - 1].total < r[i].total || (r[i - 1].total == r[i].total && r[i - 1].choice < r[i].choice));
}

TEST(assign, membership_leave_and_end) {
    cc::Membership m;
    m.systems[1] = {"a", "b"};
    m.systems[2] = {"c"};
    CHECK_EQ(m.system_of("b"), 1);
    CHECK_EQ(m.system_of("z"), 0);
    Json events = Json::make_array();
    cc::leave_system(m, "c", "stale", events);
    CHECK_EQ(events.array.size(), size_t{2});
    CHECK_EQ(events.array[1].find("ev")->string, std::string("end"));
    CHECK(!m.systems.count(2));
    CHECK_EQ(cc::system_label(12), std::string("s12"));
    CHECK_EQ(corr::to_json(cc::membership_systems_json(m)), std::string(R"({"s1":["a","b"]})"));
    cc::History h;
    h.records.resize(2);
    h.records[0].cost = 1.5;
    h.records[1].cost = 2;
    CHECK_EQ(h.total(), 3.5);
}

TEST(assign, fused_estimate_and_cost) {
    corr::Filter a, b;
    a.east = {0, 0, 1, 0, 1};
    a.north = {0, 0, 1, 0, 1};
    b.east = {10, 2, 1, 0, 1};
    b.north = {10, 2, 1, 0, 1};
    corr::Filter f = cc::fused_estimate({a, b});
    CHECK_EQ(f.east.p, 5.0);
    CHECK_EQ(f.east.pp, 0.5);
    CHECK_EQ(f.north.v, 1.0);
    cc::Entity e;
    e.filter = a;
    CHECK_EQ(cc::entry_cost(e, f, false, 2), 25.0 / 1.5 * 2);
    CHECK_EQ(cc::entry_cost(e, f, true, 2), 25.0 / 1.5 * 2 - 2);
}

TEST(assign, bias_update_pair) {
    corr::correlate::BiasParams bp{300, 10, 13.82};
    cc::BiasState st = cc::initial_bias(bp);
    CHECK_EQ(st.var, 90000.0);
    corr::Filter s, t;
    s.east = {0, 0, 100, 0, 1};
    s.north = {0, 0, 100, 0, 1};
    t.east = {50, 0, 100, 0, 1};
    t.north = {-20, 0, 100, 0, 1};
    cc::PairUpdate u = cc::update_pair(st, s, t, bp, std::nullopt);
    CHECK(u.accepted && u.state.n == 1);
    CHECK_EQ(u.state.var, 45000.0);
    CHECK_EQ(u.state.o[0], 50.0);   // the first accepted pair: o is its offset
    CHECK_EQ(u.state.o[1], -20.0);
    cc::PairUpdate timed = cc::update_pair(st, s, t, bp, 500.0);
    CHECK(timed.accepted && timed.state.S[0] > 0);
    cc::BiasState tight = st;
    tight.var = 1;
    tight.o[0] = 1e6;
    cc::PairUpdate refused = cc::update_pair(tight, s, t, bp, std::nullopt);
    CHECK(!refused.accepted && refused.state.n == 0);
    corr::Filter moved = cc::move_into_frame(t, u.state, true, false);
    CHECK_EQ(moved.east.p, 50 + u.state.o[0]);
    CHECK_EQ(cc::move_into_frame(t, u.state, false, false).east.pp, 100 + u.state.var);
}

// The ranking against its definition (every assignment, its total the sorted
// entries added from 0, all sorted, the first k), on seeded random matrices
// with forbidden entries, negative entries, ties and signed zeros.
TEST(assign, ranking_matches_definition_on_random_matrices) {
    support::Random rnd(42);
    const double values[] = {0.0, -0.0, 1.0, 1.0, 2.5, -3.0, 1e16, 1e-9, 7.25};
    for (int round = 0; round < 400; ++round) {
        const size_t n = rnd.below(round % 2 ? 8 : 6), columns = rnd.below(5), k = 1 + rnd.below(round % 3 ? 3 : 8);
        std::vector<std::vector<double>> entries(n, std::vector<double>(columns + 1));
        for (auto& row : entries)
            for (double& v : row)
                v = rnd.chance(0.25) ? INF : rnd.chance(0.5) ? values[rnd.below(9)] : (rnd.unit() - 0.4) * 100;
        // The definition.
        std::vector<cc::RankedAssignment> all;
        std::vector<size_t> choice(n);
        std::vector<bool> used(columns);
        std::function<void(size_t)> visit = [&](size_t i) {
            if (i == n) {
                std::vector<double> vs;
                for (size_t r = 0; r < n; ++r) vs.push_back(entries[r][choice[r]]);
                std::sort(vs.begin(), vs.end());
                double t = 0;
                for (double v : vs) t = t + v;
                all.push_back({choice, t});
                return;
            }
            for (size_t j = 0; j <= columns; ++j) {
                if (entries[i][j] == INF || (j < columns && used[j])) continue;
                choice[i] = j;
                if (j < columns) used[j] = true;
                visit(i + 1);
                if (j < columns) used[j] = false;
            }
        };
        visit(0);
        std::sort(all.begin(), all.end(), [](const cc::RankedAssignment& x, const cc::RankedAssignment& y) {
            return x.total != y.total ? x.total < y.total : x.choice < y.choice;
        });
        if (all.size() > k) all.resize(k);
        auto got = cc::rank_assignments(entries, columns, k);
        CHECK_EQ(got.size(), all.size());
        for (size_t r = 0; r < all.size(); ++r) {
            CHECK(got[r].choice == all[r].choice);
            CHECK(std::memcmp(&got[r].total, &all[r].total, sizeof(double)) == 0);   // the same bits
        }
    }
}

// A NaN entry takes the definition's path (each leaf's entries sorted).
TEST(assign, ranking_with_nan_entries) {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    std::vector<std::vector<double>> entries = {{nan, 1}, {2, 3}};
    auto r = cc::rank_assignments(entries, 1, 5);
    CHECK_EQ(r.size(), size_t{3});
    size_t finite = 0;
    for (const auto& a : r) finite += std::isfinite(a.total);
    CHECK_EQ(finite, size_t{2});   // (alone, 0) and (alone, alone) avoid the NaN
}
