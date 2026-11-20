// correlate-assign.md "Ranking".
#pragma once

#include <cstddef>
#include <vector>

namespace corr::correlate {

// One assignment of a source's entities.
struct RankedAssignment {
    std::vector<size_t> choice;          // choice vector: column index, or the column count for alone
    double total = 0;
};

// The first k assignments of rows to columns, in Ranking order.
// entries[i][j] for j < columns is row i against column j, entries[i][columns]
// is row i alone; +infinity is forbidden. Each column is used at most once.
std::vector<RankedAssignment> rank_assignments(const std::vector<std::vector<double>>& entries,
                                               size_t columns, size_t k);

} // namespace corr::correlate
