// The comparison of spec/vector-format.md "What the engine checks", shared by
// the correlate runner (run_vectors.cpp) and the fuse runner
// (run_fuse_vectors.cpp).
#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "json.hpp"

namespace vectors {

namespace fs = std::filesystem;
using corr::Json;

inline std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

inline std::vector<fs::path> json_files(const fs::path& dir) {
    std::vector<fs::path> out;
    if (!fs::is_directory(dir)) return out;
    for (const auto& e : fs::directory_iterator(dir))
        if (e.path().extension() == ".json") out.push_back(e.path());
    std::sort(out.begin(), out.end());
    return out;
}

// vector-format.md "What the engine checks": structural equality, numbers
// within 1e-6 * max(1, |want|), null distinct from absent. Returns the path of
// the first mismatch, or an empty string.
inline std::string mismatch(const Json& got, const Json& want, const std::string& path) {
    auto show = [](const Json& v) { return corr::to_json(v); };
    auto differ = [&](const std::string& why) {
        return path + ": " + why + " (got " + show(got) + ", want " + show(want) + ")";
    };
    if (got.kind != want.kind) return differ("type differs");
    switch (want.kind) {
        case Json::Kind::Null: return "";
        case Json::Kind::Bool: return got.boolean == want.boolean ? "" : differ("value differs");
        case Json::Kind::String: return got.string == want.string ? "" : differ("value differs");
        case Json::Kind::Number: {
            double tol = 1e-6 * std::max(1.0, std::abs(want.number));
            return std::abs(got.number - want.number) <= tol ? "" : differ("number differs");
        }
        case Json::Kind::Array: {
            size_t n = std::min(got.array.size(), want.array.size());
            for (size_t i = 0; i < n; ++i) {
                std::string m = mismatch(got.array[i], want.array[i], path + "[" + std::to_string(i) + "]");
                if (!m.empty()) return m;
            }
            if (got.array.size() != want.array.size())
                return differ("length " + std::to_string(got.array.size()) + " != " +
                              std::to_string(want.array.size()));
            return "";
        }
        case Json::Kind::Object: {
            for (const auto& kv : want.object)
                if (!got.has(kv.first)) return path + "." + kv.first + ": absent (want " + show(kv.second) + ")";
            for (const auto& kv : got.object)
                if (!want.has(kv.first)) return path + "." + kv.first + ": unexpected key (got " + show(kv.second) + ")";
            for (const auto& kv : want.object) {
                std::string m = mismatch(*got.find(kv.first), kv.second, path + "." + kv.first);
                if (!m.empty()) return m;
            }
            return "";
        }
    }
    return "";
}

} // namespace vectors
