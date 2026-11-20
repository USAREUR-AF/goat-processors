// correlate.md "Track estimate": Measurement variance, the prediction for
// comparison (with the timing variance), and d² (Tests, Restart).
#include "correlate/motion.hpp"

namespace corr::correlate {

MeasurementVariance measurement_variance(double ce, double te, const Point& v) {
    MeasurementVariance mv;
    const double ce2 = ce * ce;
    if (te == 0) {
        mv.r = {ce2, ce2};
        mv.timing = {0, 0};
        return mv;
    }
    const double ts = te / 1000;
    const double de = v.east * ts, dn = v.north * ts;
    mv.timing = {de * de, dn * dn};
    mv.r = {ce2 + mv.timing.east, ce2 + mv.timing.north};
    return mv;
}

Filter for_comparison(Filter f, const Point& timing) {
    f.east.pp = f.east.pp + timing.east;
    f.north.pp = f.north.pp + timing.north;
    return f;
}

double d2(const Point& z, const Point& r, const Filter& p) {
    double de = z.east - p.east.p, dn = z.north - p.north.p;
    return de * de / (p.east.pp + r.east) + dn * dn / (p.north.pp + r.north);
}

} // namespace corr::correlate
