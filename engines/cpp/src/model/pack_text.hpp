// What the four pack.def grammars share: the load error, reading the file,
// and correlate.md "Pack" `time_default` (quality.md "Pack" cites it).
#pragma once

#include <functional>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

#include "model/report.hpp"

namespace corr {

struct PackError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// Throws PackError("pack.def line <line>: <what>").
[[noreturn]] void pack_fail(int line, const std::string& what);

// The text of <dir>/pack.def; throws PackError when it cannot be read.
std::string read_pack_def(const std::string& dir);

// correlate.md "Pack": one `time_default` line, `words` its tokens with the
// directive first. The source id (a token without '='), then `error_ms`,
// `state` or both, each at most once; `error_ms` 0 or above, `state` one of
// the three time states; at most one line per source id. `number` reads the
// `error_ms` text in the calling pack's number grammar and throws PackError
// when it is not a number (quality.md "Pack" keeps its own grammar). Adds the
// line to `into`; throws PackError on any load error.
void parse_time_default(int line, const std::vector<std::string>& words,
                        const std::function<double(const std::string&)>& number,
                        std::map<std::string, TimeDefault>& into);

} // namespace corr
