#include "report.hpp"

#include <vector>

namespace corr::report {

bool is_integer(const Json* v) { return v && v->is_number() && v->is_int; }

std::optional<std::string> missing_required(const Json& r) {
    const std::pair<const char*, char> required[] = {
        {"track.source_id", 's'}, {"uid", 's'}, {"time_ms", 'i'}, {"lat", 'n'}, {"lon", 'n'}};
    for (const auto& req : required) {
        const Json* v = r.find(req.first);
        bool ok = req.second == 's' ? v && v->is_string()
                : req.second == 'i' ? is_integer(v)
                                    : v && v->is_number();
        if (!ok) return std::string(req.first);
    }
    return std::nullopt;
}

const Json* present(const Json& r, const std::string& key) {
    const Json* v = r.find(key);
    if (!v || v->is_null()) return nullptr;
    if (key == "hae" || key == "course" || key == "speed_ms") return v->is_number() ? v : nullptr;
    if (key == "ce") return v->is_number() && v->number > 0 ? v : nullptr;
    if (key == "type") return v->is_string() ? v : nullptr;
    if (key == "stale_ms") return is_integer(v) ? v : nullptr;
    return v;
}

std::optional<double> number_at(const Json& r, const std::string& key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

std::optional<double> ce_at(const Json& r) {
    auto ce = number_at(r, "ce");
    if (ce && *ce <= 0) return std::nullopt;
    return ce;
}

std::optional<std::int64_t> stale_ms_at(const Json& r) {
    const Json* v = r.find("stale_ms");
    if (!is_integer(v)) return std::nullopt;
    return v->integer;
}

std::optional<std::string> type_element(const Json& r, size_t index) {
    const Json* t = present(r, "type");
    if (!t) return std::nullopt;
    std::vector<std::string> parts(1);
    for (char c : t->string) {
        if (c == '-') parts.emplace_back();
        else parts.back() += c;
    }
    if (parts.size() <= index) return std::nullopt;
    return parts[index];
}

} // namespace corr::report
