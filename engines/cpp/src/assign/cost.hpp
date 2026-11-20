// correlate-assign.md "Assignment of one source": the fused estimate and the
// cost of an entry, as pure functions.
#pragma once

#include <vector>

#include "correlate/entity.hpp"
#include "model/estimate.hpp"

namespace corr::correlate {

// "Fused estimate": the given predictions (members in key order),
// inverse-variance weighted per axis. Only p, v, pp, vv are meaningful; pv is 0.
Filter fused_estimate(const std::vector<Filter>& predictions);

// "Cost": d² of A against the fused estimate f of the others, pp_a A's filter
// pp plus A's timing variance, less keep_bonus when `keeps` (A's own system
// track).
double entry_cost(const Entity& a, const Filter& f, bool keeps, double keep_bonus);

} // namespace corr::correlate
