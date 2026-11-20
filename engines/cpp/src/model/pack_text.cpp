#include "model/pack_text.hpp"

#include <fstream>
#include <sstream>

namespace corr {

void pack_fail(int line, const std::string& what) {
    throw PackError("pack.def line " + std::to_string(line) + ": " + what);
}

std::string read_pack_def(const std::string& dir) {
    std::ifstream f(dir + "/pack.def", std::ios::binary);
    if (!f) throw PackError("cannot read " + dir + "/pack.def");
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

void parse_time_default(int line, const std::vector<std::string>& words,
                        const std::function<double(const std::string&)>& number,
                        std::map<std::string, TimeDefault>& into) {
    if (words.size() < 2 || words[1].find('=') != std::string::npos)
        pack_fail(line, "time_default needs a source id");
    if (words.size() < 3) pack_fail(line, "time_default needs error_ms, state or both");
    TimeDefault td;
    for (size_t k = 2; k < words.size(); ++k) {
        size_t eq = words[k].find('=');
        if (eq == std::string::npos || eq == 0) pack_fail(line, "parameter without '=': " + words[k]);
        std::string name = words[k].substr(0, eq), value = words[k].substr(eq + 1);
        if (name == "error_ms") {
            if (td.error_ms) pack_fail(line, "repeated parameter: error_ms");
            double ms = number(value);
            if (!(ms >= 0)) pack_fail(line, "time_default error_ms must be 0 or above");
            td.error_ms = ms;
        } else if (name == "state") {
            if (td.state) pack_fail(line, "repeated parameter: state");
            if (!report::is_time_state(value))
                pack_fail(line, "time_default state is coherent, drifting or free-running");
            td.state = value;
        } else {
            pack_fail(line, "unknown parameter: " + name);
        }
    }
    if (!into.emplace(words[1], td).second) pack_fail(line, "repeated time_default source: " + words[1]);
}

} // namespace corr
