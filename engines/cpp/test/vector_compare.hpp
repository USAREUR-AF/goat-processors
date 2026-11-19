// The comparison of spec/vector-format.md, "What the engine checks", shared
// by the correlate and quality vector runners.
#pragma once

#include <algorithm>
#include <cmath>
#include <string>

#include "json.hpp"

namespace corr {

// vector-format.md "What the engine checks": structural equality, numbers
// within 1e-6 * max(1, |want|), null distinct from absent. Returns the path of
// the first mismatch, or an empty string.
inline std::string mismatch(const corr::Json& got, const corr::Json& want, const std::string& path) {
    auto show = [](const corr::Json& v) { return corr::to_json(v); };
    auto differ = [&](const std::string& why) {
        return path + ": " + why + " (got " + show(got) + ", want " + show(want) + ")";
    };
    if (got.kind != want.kind) return differ("type differs");
    switch (want.kind) {
        case corr::Json::Kind::Null: return "";
        case corr::Json::Kind::Bool: return got.boolean == want.boolean ? "" : differ("value differs");
        case corr::Json::Kind::String: return got.string == want.string ? "" : differ("value differs");
        case corr::Json::Kind::Number: {
            double tol = 1e-6 * std::max(1.0, std::abs(want.number));
            return std::abs(got.number - want.number) <= tol ? "" : differ("number differs");
        }
        case corr::Json::Kind::Array: {
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
        case corr::Json::Kind::Object: {
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

} // namespace corr
