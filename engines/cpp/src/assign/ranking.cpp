// correlate-assign.md "Ranking".
#include "assign/ranking.hpp"

#include <algorithm>
#include <functional>
#include <limits>

namespace corr::correlate {

namespace {

const double INF = std::numeric_limits<double>::infinity();

// The total of an assignment: its chosen entries in ascending order of value,
// added left to right from 0.
double assignment_total(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    double t = 0;
    for (double v : values) t = t + v;
    return t;
}

// X ranks before Y: smaller total, or equal totals and the smaller choice
// vector at the first entity where they differ.
bool ranks_before(const RankedAssignment& x, const RankedAssignment& y) {
    if (x.total != y.total) return x.total < y.total;
    return x.choice < y.choice;   // lexicographic
}

} // namespace

// Brute force: every assignment (each column at most once, no forbidden
// entry), then the first k in Ranking order.
std::vector<RankedAssignment> rank_assignments(const std::vector<std::vector<double>>& entries,
                                               size_t columns, size_t k) {
    const size_t n = entries.size();
    std::vector<RankedAssignment> all;
    std::vector<size_t> choice(n, 0);
    std::vector<bool> used(columns, false);
    std::function<void(size_t)> visit = [&](size_t i) {
        if (i == n) {
            std::vector<double> values;
            for (size_t r = 0; r < n; ++r) values.push_back(entries[r][choice[r]]);
            all.push_back({choice, assignment_total(values)});
            return;
        }
        for (size_t j = 0; j <= columns; ++j) {          // j == columns is alone
            if (entries[i][j] == INF) continue;
            if (j < columns && used[j]) continue;
            choice[i] = j;
            if (j < columns) used[j] = true;
            visit(i + 1);
            if (j < columns) used[j] = false;
        }
    };
    visit(0);
    std::sort(all.begin(), all.end(), ranks_before);
    if (all.size() > k) all.resize(k);
    return all;
}

} // namespace corr::correlate
