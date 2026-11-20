// correlate.md "Track estimate": Measurement variance and the prediction for
// comparison (with the timing variance).
#include "correlate/engine.hpp"

#include "correlate/common.hpp"

namespace corr::correlate {

using namespace detail;

// correlate.md "Track estimate", Measurement variance. `e` is the entity for a
// later report (its prediction to time_ms gives the velocity), or null for a
// first report (the measured velocity, or 0 without one). `te` is the
// report's time error in ms (Reports, "Time quality").
MeasurementVariance Engine::measurement_variance(const Entity* e, std::int64_t time_ms,
                                                 const std::optional<Point>& vel, double ce, double te) const {
    MeasurementVariance mv;
    const double ce2 = ce * ce;
    if (te == 0) {
        mv.r = {ce2, ce2};
        mv.timing = {0, 0};
        return mv;
    }
    const double ts = te / 1000;
    Point v = {0, 0};
    if (e) {
        Filter p = predict(*e, time_ms);
        v = {p.east.v, p.north.v};
    } else if (vel) {
        v = *vel;
    }
    const double de = v.east * ts, dn = v.north * ts;
    mv.timing = {de * de, dn * dn};
    mv.r = {ce2 + mv.timing.east, ce2 + mv.timing.north};
    return mv;
}

// correlate.md "Track estimate": B predicted to t to be compared with another
// entity, with B's timing variance added to the predicted pp on each axis
// before any other change to the prediction (Tests, rank, and
// correlate-assign.md Cost). Restart, the bias update and output use
// `predict`, without it.
Filter Engine::predict_for_comparison(const Entity& b, std::int64_t t) const {
    Filter f = predict(b, t);
    f.east.pp = f.east.pp + b.timing.east;
    f.north.pp = f.north.pp + b.timing.north;
    return f;
}

} // namespace corr::correlate
