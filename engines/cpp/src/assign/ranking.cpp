// correlate-assign.md "Ranking".
#include "assign/ranking.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace corr::correlate {

namespace {

const double INF = std::numeric_limits<double>::infinity();

// The total of an assignment: its chosen entries in ascending order of value,
// added left to right from 0. `values` is scratch space, sorted in place.
double assignment_total(double* values, size_t n) {
    std::sort(values, values + n);
    double t = 0;
    for (size_t i = 0; i < n; ++i) t = t + values[i];
    return t;
}

// X ranks before Y: smaller total, or equal totals and the smaller choice
// vector at the first entity where they differ.
bool ranks_before(double x_total, const size_t* x_choice, double y_total, const size_t* y_choice, size_t n) {
    if (x_total != y_total) return x_total < y_total;
    return std::lexicographical_compare(x_choice, x_choice + n, y_choice, y_choice + n);
}

bool ranks_first(const RankedAssignment& x, const RankedAssignment& y) {
    return ranks_before(x.total, x.choice.data(), y.total, y.choice.data(), x.choice.size());
}

// Visits every assignment (each column at most once, no forbidden entry) and
// keeps the first k in Ranking order. Ranking order is a strict total order
// (no two assignments have the same choice vector), so keeping the best k as
// they come gives exactly the first k of all of them sorted. The kept ones
// are a heap with the one that ranks last on top; an assignment that ranks
// after it once k are kept is dropped without allocating.
//
// The total adds the chosen entries in ascending order. The search keeps the
// entries chosen so far sorted (sorted_), and at the last row the prefix sums
// of that order (prefix_), so a leaf's total is prefix_[p] + v, then the
// entries after position p, one by one: the same additions in the same order
// as sorting the leaf's entries and adding them from 0. Equal entries are
// interchangeable (the sum never holds -0, so +0 and -0 add alike). A row
// set holding a NaN is ranked by sorting each leaf, as the definition reads.
//
// Once k are kept, a partial assignment is not extended when no completion
// can rank before the last kept one: the least real sum of any completion
// (the entries chosen so far plus, per remaining row, its least allowed
// entry) exceeds the last kept total by more than 1e-9 of the sum of the
// magnitudes involved. A computed total differs from the real sum by at most
// about n * 2^-53 of those magnitudes, far below that margin, so every
// completion's computed total is above the last kept one and none of them
// would be kept: the result is the same as visiting them.
class Ranker {
public:
    Ranker(const std::vector<std::vector<double>>& entries, size_t columns, size_t k)
        : entries_(entries), n_(entries.size()), columns_(columns), k_(k), choice_(n_, 0), values_(n_, 0),
          used_(columns, 0) {
        for (const auto& row : entries)
            for (double v : row) has_nan_ = has_nan_ || v != v;
        sorted_.reserve(n_);
        prefix_.resize(n_ + 1);
        // Per row from i on: the sum of each row's least allowed entry, and of
        // its largest magnitude.
        rest_min_.assign(n_ + 1, 0);
        rest_abs_.assign(n_ + 1, 0);
        for (size_t i = n_; i-- > 0;) {
            double least = INF, mag = 0;
            for (double v : entries[i])
                if (v != INF) {
                    least = std::min(least, v);
                    mag = std::max(mag, std::abs(v));
                }
            rest_min_[i] = rest_min_[i + 1] + least;
            rest_abs_[i] = rest_abs_[i + 1] + mag;
        }
    }

    std::vector<RankedAssignment> run() {
        if (k_ > 0) visit(0);
        std::sort_heap(kept_.begin(), kept_.end(), ranks_first);   // ascending: first ranks first
        return std::move(kept_);
    }

private:
    void visit(size_t i) {
        if (i == n_) {
            leaf(has_nan_ || n_ == 0 ? sorted_total() : 0);
            return;
        }
        if (!has_nan_ && kept_.size() == k_) {
            const double least = chosen_sum_ + rest_min_[i];
            const double margin = 1e-9 * (chosen_abs_ + rest_abs_[i] + std::abs(kept_.front().total)) + 1e-300;
            if (least - margin > kept_.front().total) return;
        }
        const std::vector<double>& row = entries_[i];
        const bool last = !has_nan_ && i + 1 == n_;
        if (last) {
            // prefix_[p]: the first p sorted entries added left to right from 0.
            prefix_[0] = 0;
            for (size_t p = 0; p < sorted_.size(); ++p) prefix_[p + 1] = prefix_[p] + sorted_[p];
        }
        for (size_t j = 0; j <= columns_; ++j) {          // j == columns is alone
            const double v = row[j];
            if (v == INF) continue;
            if (j < columns_ && used_[j]) continue;
            choice_[i] = j;
            if (last) {
                const size_t p = static_cast<size_t>(std::upper_bound(sorted_.begin(), sorted_.end(), v) -
                                                     sorted_.begin());
                double t = prefix_[p] + v;
                for (size_t q = p; q < sorted_.size(); ++q) t = t + sorted_[q];
                leaf(t);
                continue;
            }
            if (j < columns_) used_[j] = 1;
            const double sum_before = chosen_sum_, abs_before = chosen_abs_;
            chosen_sum_ = chosen_sum_ + v;
            chosen_abs_ = chosen_abs_ + std::abs(v);
            if (!has_nan_) sorted_.insert(std::upper_bound(sorted_.begin(), sorted_.end(), v), v);
            visit(i + 1);
            if (!has_nan_) sorted_.erase(std::upper_bound(sorted_.begin(), sorted_.end(), v) - 1);
            chosen_sum_ = sum_before;
            chosen_abs_ = abs_before;
            if (j < columns_) used_[j] = 0;
        }
    }

    // The total by its definition: the leaf's entries sorted, added from 0.
    double sorted_total() {
        for (size_t r = 0; r < n_; ++r) values_[r] = entries_[r][choice_[r]];
        return assignment_total(values_.data(), n_);
    }

    void leaf(double total) {
        if (kept_.size() == k_) {
            const RankedAssignment& last = kept_.front();
            if (!ranks_before(total, choice_.data(), last.total, last.choice.data(), n_)) return;
            std::pop_heap(kept_.begin(), kept_.end(), ranks_first);
            kept_.back().choice.assign(choice_.begin(), choice_.end());
            kept_.back().total = total;
        } else {
            kept_.push_back({choice_, total});
        }
        std::push_heap(kept_.begin(), kept_.end(), ranks_first);
    }

    const std::vector<std::vector<double>>& entries_;
    const size_t n_, columns_, k_;
    bool has_nan_ = false;
    std::vector<size_t> choice_;
    std::vector<double> values_;
    std::vector<char> used_;
    std::vector<double> sorted_, prefix_;
    std::vector<double> rest_min_, rest_abs_;   // the bound, per row from i on
    double chosen_sum_ = 0, chosen_abs_ = 0;    // of the entries chosen so far
    std::vector<RankedAssignment> kept_;
};

} // namespace

// Brute force over every assignment, keeping the first k in Ranking order.
std::vector<RankedAssignment> rank_assignments(const std::vector<std::vector<double>>& entries,
                                               size_t columns, size_t k) {
    return Ranker(entries, columns, k).run();
}

} // namespace corr::correlate
