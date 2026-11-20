#include "io/files.hpp"

#include <fstream>
#include <sstream>
#include <stdexcept>

namespace corr::io {

std::string read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot read " + path);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

} // namespace corr::io
