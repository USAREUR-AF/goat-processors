// Reading files whole (the runner's steps file, the vectors).
#pragma once

#include <string>

namespace corr::io {

// The bytes of `path`; throws std::runtime_error when it cannot be read.
std::string read_file(const std::string& path);

} // namespace corr::io
