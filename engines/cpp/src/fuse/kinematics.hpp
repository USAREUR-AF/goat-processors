// fuse.md "Kinematics": the five methods that combine a group's predicted
// members into one estimate.
#pragma once

#include <string>
#include <vector>

#include "fuse/entity.hpp"
#include "fuse/pack.hpp"
#include "model/output.hpp"

namespace corr::fuse {

// A member's filter predicted to now_ms (fuse.md "On each tick", 2.1).
struct Predicted {
    const Entity* entity;
    Filter f;
    double var() const { return f.east.pp + f.north.pp; }   // "Position variance"
};

// The combined kinematics and the member it came from (null for the two
// weighted methods).
struct Kinematics {
    Filter f;
    const Entity* from = nullptr;
};

// Combines `members` (key order) of group `g` by `method`; the
// covariance_intersection folds go to `out.trace`.
Kinematics combine(Method method, const Group& g, const std::vector<Predicted>& members,
                   const std::vector<std::string>& sources, Output& out);

} // namespace corr::fuse
