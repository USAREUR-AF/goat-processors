#include "snapshot/snapshot.hpp"

namespace corr::snapshot {

Json axis_json(const Axis& a) {
    Json j = Json::make_array();
    for (double x : {a.p, a.v, a.pp, a.pv, a.vv}) j.push(x);
    return j;
}

Json filter_json(const Filter& f) {
    Json j = Json::make_object();
    j["east"] = axis_json(f.east);
    j["north"] = axis_json(f.north);
    return j;
}

Json ref_json(const std::optional<std::pair<double, double>>& ref) {
    if (!ref) return Json();
    Json j = Json::make_array();
    j.push(ref->first);
    j.push(ref->second);
    return j;
}

} // namespace corr::snapshot
