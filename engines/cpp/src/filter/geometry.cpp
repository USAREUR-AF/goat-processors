// filter.md "Geometry".
#include "filter/geometry.hpp"

#include <algorithm>
#include <cmath>

namespace corr::filter {

namespace {

constexpr double R = 6371008.8;
constexpr double PI = 3.141592653589793;
double rad(double x) { return x * PI / 180; }
double deg(double x) { return x * 180 / PI; }

} // namespace

double wrap(double x) {
    if (!std::isfinite(x)) return x;
    if (std::abs(x) > 1e6) x = std::fmod(x, 360.0);
    while (x > 180) x -= 360;
    while (x <= -180) x += 360;
    return x;
}

double distance(double lat1, double lon1, double lat2, double lon2) {
    double p1 = rad(lat1), p2 = rad(lat2), dp = rad(lat2 - lat1), dl = rad(wrap(lon2 - lon1));  // 1
    double s1 = std::sin(dp / 2), s2 = std::sin(dl / 2);                                         // 2
    double h = s1 * s1 + ((std::cos(p1) * std::cos(p2)) * s2) * s2;                              // 3
    return (2 * R) * std::asin(std::min(1.0, std::sqrt(h)));                                      // 4
}

const char* polygon_test(const std::vector<std::pair<double, double>>& vertices, double lat, double lon) {
    const size_t n = vertices.size();
    const double lon0 = vertices[0].second;
    std::vector<double> x(n), y(n);
    for (size_t i = 0; i < n; ++i) {
        x[i] = i == 0 ? lon0 : lon0 + wrap(vertices[i].second - lon0);
        y[i] = vertices[i].first;
    }
    const double px = lon0 + wrap(lon - lon0), py = lat;

    // 1. Boundary.
    for (size_t i = 0; i < n; ++i) {
        size_t j = (i + 1) % n;
        double c = (x[j] - x[i]) * (py - y[i]) - (y[j] - y[i]) * (px - x[i]);
        if (c == 0 && std::min(x[i], x[j]) <= px && px <= std::max(x[i], x[j]) &&
            std::min(y[i], y[j]) <= py && py <= std::max(y[i], y[j]))
            return "boundary";
    }
    // 2. Crossings (even-odd).
    bool inside = false;
    for (size_t i = 0; i < n; ++i) {
        size_t j = (i + 1) % n;
        if ((y[i] > py) != (y[j] > py)) {
            double xc = (x[j] - x[i]) * (py - y[i]) / (y[j] - y[i]) + x[i];
            if (px < xc) inside = !inside;
        }
    }
    return inside ? "inside" : "outside";
}

std::pair<double, double> predict(const Fix& ref, std::int64_t t) {
    double dt = static_cast<double>(t - ref.time_ms) / 1000;                     // 1
    double dn = 0, de = 0;                                                       // 2
    if (ref.course && ref.speed_ms) {
        dn = *ref.speed_ms * std::cos(rad(*ref.course)) * dt;
        de = *ref.speed_ms * std::sin(rad(*ref.course)) * dt;
    }
    double lat_p = ref.lat + deg(dn / R);                                        // 3
    double lon_p = wrap(ref.lon + deg(de / (R * std::cos(rad(ref.lat)))));
    return {lat_p, lon_p};
}

} // namespace corr::filter
