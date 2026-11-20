// correlate-assign.md "Sensor bias", with "Time offset".
#include "correlate/engine.hpp"

#include "correlate/common.hpp"

namespace corr::correlate {

using namespace detail;

// "State": a pair with no stored state reads as o = 0, w = 0, var = s², n = 0.
BiasState Engine::bias_state(const std::string& pair) const {
    auto it = bias_.find(pair);
    if (it != bias_.end()) return it->second;
    BiasState st;
    st.var = pack_.bias->sigma_m * pack_.bias->sigma_m;
    return st;
}

// "Moving B into A's frame": B predicted to t for comparison with A (its
// timing variance added first, correlate.md "Track estimate"), then, when the
// pack has `bias` and the two sources differ, p + o (b_src first in key
// order) or p - o (a_src first) on each axis, with pp + var. With
// `time_offset` ("Time offset") the offset on each axis is o - v*tau, v B's
// predicted velocity on that axis. Without `bias` this is B's prediction for
// comparison.
Filter Engine::predict_into_frame(const Entity& a, const Entity& b, std::int64_t t) const {
    Filter f = predict_for_comparison(b, t);
    if (!pack_.bias || a.source == b.source) return f;
    const bool b_first = b.source < a.source;
    const BiasState st = bias_state(b_first ? b.source + "|" + a.source : a.source + "|" + b.source);
    Axis* ax[2] = {&f.east, &f.north};
    for (int i = 0; i < 2; ++i) {
        const double offset = pack_.time_offset_sigma_ms ? st.o[i] - ax[i]->v * st.tau : st.o[i];
        ax[i]->p = b_first ? ax[i]->p + offset : ax[i]->p - offset;
        ax[i]->pp = ax[i]->pp + st.var;
    }
    return f;
}

// "Time offset", an accepted pair: add the pair to the sums S1 to S8, then
// the closed-form weighted least-squares fit of y = o - v*tau with priors of
// 0 for o (standard deviation s) and tau (standard deviation t ms). r, v, y
// are the pair's east and north values of Update step 1.
void Engine::fit_time_offset(BiasState& st, const double r[2], const double v[2], const double y[2]) const {
    const double we = 1 / r[0], wn = 1 / r[1];
    const double ve = v[0], vn = v[1], ye = y[0], yn = y[1];
    double* S = st.S;
    S[0] = S[0] + we;                                // S1
    S[1] = S[1] + wn;                                // S2
    S[2] = S[2] + we * ve;                           // S3
    S[3] = S[3] + wn * vn;                           // S4
    S[4] = S[4] + (we * ve * ve + wn * vn * vn);     // S5
    S[5] = S[5] + we * ye;                           // S6
    S[6] = S[6] + wn * yn;                           // S7
    S[7] = S[7] + (we * ve * ye + wn * vn * yn);     // S8

    const double s = pack_.bias->sigma_m, t = *pack_.time_offset_sigma_ms;
    const double po = 1 / (s * s);
    const double t_s = t / 1000;
    const double pt = 1 / (t_s * t_s);
    const double a11 = po + S[0], a22 = po + S[1];
    const double a13 = -S[2], a23 = -S[3];
    const double a33 = pt + S[4];
    const double b1 = S[5], b2 = S[6], b3 = -S[7];
    st.tau = (b3 - a13 * b1 / a11 - a23 * b2 / a22) / (a33 - a13 * a13 / a11 - a23 * a23 / a22);
    st.o[0] = (b1 - a13 * st.tau) / a11;
    st.o[1] = (b2 - a23 * st.tau) / a22;
    st.w[0] = S[0];   // the weight sum of each axis is S1 and S2
    st.w[1] = S[1];
}

// "Update", after the commit: committed system tracks in creation order,
// members not retiring in key order, each pair X before Y from two different
// sources with at least one of them among the tick's rows.
void Engine::bias_update(std::int64_t now_ms, const std::set<std::string>& rows, Output& out) {
    const BiasParams& bp = *pack_.bias;
    for (const auto& kv : committed_.systems) {
        std::vector<std::string> members;
        for (const std::string& key : kv.second)
            if (!retiring_.count(key)) members.push_back(key);
        for (size_t x = 0; x < members.size(); ++x) {
            for (size_t y = x + 1; y < members.size(); ++y) {
                const Entity& ex = entities_.at(members[x]);
                const Entity& ey = entities_.at(members[y]);
                if (ex.source == ey.source) continue;
                if (!rows.count(ex.key) && !rows.count(ey.key)) continue;

                // 1. ES is the entity whose source is first in key order.
                const bool x_first = ex.source < ey.source;
                const Entity& es = x_first ? ex : ey;
                const Entity& et = x_first ? ey : ex;
                const std::string pair = es.source + "|" + et.source;
                Filter fs = predict(es, now_ms), ft = predict(et, now_ms);
                const Axis* as[2] = {&fs.east, &fs.north};
                const Axis* at[2] = {&ft.east, &ft.north};
                const bool timed = pack_.time_offset_sigma_ms.has_value();
                double yv[2], r[2], v[2];
                for (int i = 0; i < 2; ++i) {
                    yv[i] = at[i]->p - as[i]->p;
                    r[i] = as[i]->pp + at[i]->pp;
                    v[i] = (as[i]->v + at[i]->v) / 2;   // "Time offset": the pair's velocity
                }

                // 2. d² with the pair's state; with `time_offset` the expected
                //    offset is o - v*tau.
                BiasState st = bias_state(pair);
                double d2 = 0;
                for (int i = 0; i < 2; ++i) {
                    double dev = timed ? yv[i] - (st.o[i] - v[i] * st.tau) : yv[i] - st.o[i];
                    d2 = d2 + dev * dev / (st.var + r[i]);
                }

                // 3. Accepted when d² < g.
                const bool accepted = d2 < bp.gate;
                if (accepted) {
                    st.n = st.n + 1;
                    st.var = bp.sigma_m * bp.sigma_m / static_cast<double>(st.n + 1);
                    const double floor2 = bp.floor_m * bp.floor_m;
                    if (st.var < floor2) st.var = floor2;
                    if (timed) {
                        fit_time_offset(st, r, v, yv);
                    } else {
                        for (int i = 0; i < 2; ++i) {
                            st.w[i] = st.w[i] + 1 / r[i];
                            st.o[i] = st.o[i] + ((1 / r[i]) / st.w[i]) * (yv[i] - st.o[i]);
                        }
                    }
                    bias_[pair] = st;
                }

                // 4. Trace, with the state after step 3.
                Json rec = Json::make_object();
                rec["stage"] = "bias";
                rec["a"] = ex.key;
                rec["b"] = ey.key;
                rec["test"] = "offset";
                rec["value"] = d2;
                rec["limit"] = bp.gate;
                rec["pass"] = accepted;
                rec["east"] = st.o[0];
                rec["north"] = st.o[1];
                rec["var"] = st.var;
                rec["pairs"] = static_cast<long long>(st.n);
                if (timed) rec["time_offset_ms"] = st.tau * 1000;
                out.trace.push(rec);
            }
        }
    }
}

} // namespace corr::correlate
