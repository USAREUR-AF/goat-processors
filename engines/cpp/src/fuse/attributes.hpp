// fuse.md "Attributes": the five rules that pick one member's value of a key.
#pragma once

#include <string>
#include <vector>

#include "fuse/entity.hpp"
#include "fuse/pack.hpp"
#include "model/output.hpp"

namespace corr::fuse {

// Decides one `attribute` line for group `g`: adds `{value, from}` to
// `attributes` when there is a candidate, and writes its trace record.
void decide_attribute(const Group& g, const Attribute& attr, const std::vector<std::string>& sources,
                      Json& attributes, Output& out);

} // namespace corr::fuse
