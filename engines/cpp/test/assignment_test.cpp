// Checks min_cost_assignment against brute force on random matrices shaped
// like correlate-assign.md step 3: n rows, m columns plus one `alone` column
// per row, forbidden entries as +infinity.

#include <cmath>
#include <iostream>
#include <limits>
#include <random>
#include <vector>

#include "engine.hpp"

namespace {

const double INF = std::numeric_limits<double>::infinity();

void brute(const std::vector<std::vector<double>>& c, size_t i, std::vector<bool>& used, double sum, double& best) {
    if (i == c.size()) {
        if (sum < best) best = sum;
        return;
    }
    for (size_t j = 0; j < c[i].size(); ++j) {
        if (used[j] || c[i][j] == INF) continue;
        used[j] = true;
        brute(c, i + 1, used, sum + c[i][j], best);
        used[j] = false;
    }
}

} // namespace

int main() {
    std::mt19937_64 rng(12345);
    std::uniform_real_distribution<double> cost(-3, 12);
    std::uniform_int_distribution<int> coin(0, 3);
    int failures = 0;
    for (int trial = 0; trial < 20000; ++trial) {
        size_t n = 1 + trial % 5, m = trial % 6;
        std::vector<std::vector<double>> c(n, std::vector<double>(m + n, INF));
        for (size_t i = 0; i < n; ++i) {
            for (size_t j = 0; j < m; ++j)
                if (coin(rng)) c[i][j] = cost(rng);
            c[i][m + i] = cost(rng);
        }
        std::vector<int> got = corr::min_cost_assignment(c);
        double sum = 0;
        std::vector<bool> seen(m + n, false);
        bool valid = got.size() == n;
        for (size_t i = 0; valid && i < n; ++i) {
            int j = got[i];
            valid = j >= 0 && static_cast<size_t>(j) < m + n && !seen[j] && c[i][j] != INF;
            if (valid) { seen[j] = true; sum += c[i][j]; }
        }
        std::vector<bool> used(m + n, false);
        double best = INF;
        brute(c, 0, used, 0, best);
        if (!valid || std::abs(sum - best) > 1e-9) {
            ++failures;
            std::cout << "FAIL trial " << trial << ": got " << sum << ", want " << best << "\n";
        }
    }
    std::cout << (failures ? "FAIL" : "PASS") << " assignment: 20000 random matrices against brute force\n";
    return failures ? 1 : 0;
}
