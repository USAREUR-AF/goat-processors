// correlate.md "Frame": the local plane around the reference (lat0, lon0).
// Shared by correlate, fuse and quality (quality.md "Frame and filter").
#pragma once

#include <cmath>
#include <utility>

namespace corr {

constexpr double EARTH_R = 6371008.8;
constexpr double PI = 3.141592653589793;
inline double rad(double x) { return x * PI / 180; }
inline double deg(double x) { return x * 180 / PI; }
// Brings a longitude into (-180, 180].
double wrap180(double lon);

struct Point {
    double east, north;
};

// Degrees to meters east and north of the reference (lat0, lon0).
Point to_plane(double lat0, double lon0, double lat, double lon);
// Meters east and north of the reference back to (lat, lon) in degrees.
std::pair<double, double> to_degrees(double lat0, double lon0, double east, double north);

// course = deg(atan2(ve, vn)) in [0, 360).
inline double course_of(double ve, double vn) {
    double course = deg(std::atan2(ve, vn));
    if (course < 0) course += 360;
    if (course >= 360) course -= 360;
    return course;
}

} // namespace corr
