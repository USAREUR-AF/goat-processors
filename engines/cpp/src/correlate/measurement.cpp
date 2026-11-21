// correlate.md "Track estimate": Measurement variance, the prediction for
// comparison (with the timing variance), and d² (Tests, Restart).
#include "correlate/motion.hpp"

#include <cmath>

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

// correlate.md "Tests", the `state` test (Bar-Shalom 1981), in the order written.
StateAxis state_axis(const Axis& a, double ta, const Axis& b) {
    StateAxis s;
    s.dp = a.p - b.p;
    s.dv = a.v - b.v;
    s.spp = a.pp + ta + b.pp;
    s.spv = a.pv + b.pv;
    s.svv = a.vv + b.vv;
    s.det = s.spp * s.svv - s.spv * s.spv;
    s.q = (s.svv * s.dp * s.dp - 2 * s.spv * s.dp * s.dv + s.spp * s.dv * s.dv) / s.det;
    return s;
}

// correlate.md "Association", Sequential test: "different objects" is the
// same Gaussian difference with the spread P = pos_m², V = vel_ms² added.
SprtEvidence sprt_evidence(const Filter& a, const Point& ta, const Filter& bp, const std::optional<double>& ha,
                           const std::optional<double>& hb, const SprtParams& sp) {
    const double P = sp.pos_m * sp.pos_m, V = sp.vel_ms * sp.vel_ms;
    auto term = [&](const StateAxis& s, double& q) {
        const double tpp = s.spp + P, tvv = s.svv + V;
        const double det0 = tpp * tvv - s.spv * s.spv;
        const double q0 = (tvv * s.dp * s.dp - 2 * s.spv * s.dp * s.dv + tpp * s.dv * s.dv) / det0;
        q = s.q;
        return 0.5 * (q0 - s.q) + 0.5 * std::log(det0 / s.det);
    };
    double qe = 0, qn = 0;
    double increment = 0;
    increment = increment + term(state_axis(a.east, ta.east, bp.east), qe);
    increment = increment + term(state_axis(a.north, ta.north, bp.north), qn);
    double d2 = qe + qn;
    if (ha && hb) {
        const double h1 = 2 * sp.hae_sigma_m * sp.hae_sigma_m, h0 = h1 + P, dh = *ha - *hb;
        increment = increment + (0.5 * (dh * dh / h0 - dh * dh / h1) + 0.5 * std::log(h0 / h1));
        d2 = d2 + dh * dh / h1;
    }
    return {increment, d2};
}

} // namespace corr::correlate
