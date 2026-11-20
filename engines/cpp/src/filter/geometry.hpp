// filter.md "Geometry": distance, polygon and the reference prediction.
// Pure functions of their arguments.
#pragma once

#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace corr::filter {

// wrap(x): add or subtract 360 until x is in (-180, 180]. A value too large
// for the loop to end (only near a pole, an open point; see DISAGREEMENTS.md)
// is first reduced with the exact fmod; a non-finite value is returned as is.
double wrap(double x);

// Distance: haversine from point 1 (the report) to point 2, in the spec's order.
double distance(double lat1, double lon1, double lat2, double lon2);

// Polygon: "boundary", "inside" or "outside".
const char* polygon_test(const std::vector<std::pair<double, double>>& vertices, double lat, double lon);

// What the reference prediction reads of a stored entity.
struct Fix {
    std::int64_t time_ms = 0;
    double lat = 0, lon = 0;
    std::optional<double> course, speed_ms;
};

// Reference prediction: the reference's stored position predicted to time t.
std::pair<double, double> predict(const Fix& ref, std::int64_t t);

} // namespace corr::filter
