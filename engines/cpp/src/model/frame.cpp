// correlate.md "Frame".
#include "model/frame.hpp"

namespace corr {

double wrap180(double lon) {
    while (lon > 180) lon -= 360;
    while (lon <= -180) lon += 360;
    return lon;
}

Point to_plane(double lat0, double lon0, double lat, double lon) {
    double dlon = wrap180(lon - lon0);
    return {EARTH_R * rad(dlon) * std::cos(rad(lat0)), EARTH_R * rad(lat - lat0)};
}

std::pair<double, double> to_degrees(double lat0, double lon0, double east, double north) {
    double lat = lat0 + deg(north / EARTH_R);
    double lon = lon0 + deg(east / (EARTH_R * std::cos(rad(lat0))));
    return {lat, wrap180(lon)};
}

} // namespace corr
