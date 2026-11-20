// correlate-assign.md "Sensor bias", with "Time offset".
#include "assign/bias.hpp"

#include <string>
#include <vector>

#include "correlate/common.hpp"
#include "assign/assign.hpp"

namespace corr::correlate {

using namespace detail;

namespace {

// "Time offset", an accepted pair: add the pair to the sums S1 to S8, then
// the closed-form weighted least-squares fit of y = o - v*tau with priors of
// 0 for o (standard deviation s) and tau (standard deviation t ms). r, v, y
// are the pair's east and north values of Update step 1.
BiasState fit_time_offset(BiasState st, const double r[2], const double v[2], const double y[2], double s,
                          double t) {
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
    return st;
}

} // namespace

BiasState initial_bias(const BiasParams& b) {
    BiasState st;
    st.var = b.sigma_m * b.sigma_m;
    return st;
}

Filter move_into_frame(Filter f, const BiasState& st, bool b_first, bool timed) {
    Axis* ax[2] = {&f.east, &f.north};
    for (int i = 0; i < 2; ++i) {
        const double offset = timed ? st.o[i] - ax[i]->v * st.tau : st.o[i];
        ax[i]->p = b_first ? ax[i]->p + offset : ax[i]->p - offset;
        ax[i]->pp = ax[i]->pp + st.var;
    }
    return f;
}

PairUpdate update_pair(const BiasState& st0, const Filter& fs, const Filter& ft, const BiasParams& bp,
                       const std::optional<double>& time_offset_sigma_ms) {
    // 1. The pair's offset, variance and (Time offset) velocity per axis.
    const Axis* as[2] = {&fs.east, &fs.north};
    const Axis* at[2] = {&ft.east, &ft.north};
    const bool timed = time_offset_sigma_ms.has_value();
    double yv[2], r[2], v[2];
    for (int i = 0; i < 2; ++i) {
        yv[i] = at[i]->p - as[i]->p;
        r[i] = as[i]->pp + at[i]->pp;
        v[i] = (as[i]->v + at[i]->v) / 2;
    }

    // 2. d² with the pair's state; with `time_offset` the expected offset is o - v*tau.
    PairUpdate u;
    u.state = st0;
    for (int i = 0; i < 2; ++i) {
        double dev = timed ? yv[i] - (st0.o[i] - v[i] * st0.tau) : yv[i] - st0.o[i];
        u.d2 = u.d2 + dev * dev / (st0.var + r[i]);
    }

    // 3. Accepted when d² < g.
    u.accepted = u.d2 < bp.gate;
    if (!u.accepted) return u;
    BiasState& st = u.state;
    st.n = st.n + 1;
    st.var = bp.sigma_m * bp.sigma_m / static_cast<double>(st.n + 1);
    const double floor2 = bp.floor_m * bp.floor_m;
    if (st.var < floor2) st.var = floor2;
    if (timed) {
        st = fit_time_offset(st, r, v, yv, bp.sigma_m, *time_offset_sigma_ms);
    } else {
        for (int i = 0; i < 2; ++i) {
            st.w[i] = st.w[i] + 1 / r[i];
            st.o[i] = st.o[i] + ((1 / r[i]) / st.w[i]) * (yv[i] - st.o[i]);
        }
    }
    return u;
}

// ---- The engine's use of the pair states ----------------------------------------

BiasState AssignMethod::bias_state(const std::string& pair) const {
    auto it = bias_.find(pair);
    return it != bias_.end() ? it->second : initial_bias(*pack_.bias);
}

// B predicted to t for comparison with A (its timing variance added first,
// correlate.md "Track estimate"), then, when the pack has `bias` and the two
// sources differ, moved into A's frame. Without `bias` this is B's
// prediction for comparison.
Filter AssignMethod::predict_into_frame(const Entity& a, const Entity& b, std::int64_t t) const {
    Filter f = predict_for_comparison(b, t);
    if (!pack_.bias || a.source == b.source) return f;
    const bool b_first = b.source < a.source;
    return move_into_frame(f, bias_state(b_first ? b.source + "|" + a.source : a.source + "|" + b.source), b_first,
                           pack_.time_offset_sigma_ms.has_value());
}

// "Update", after the commit: committed system tracks in creation order,
// members not retiring in key order, each pair X before Y from two different
// sources with at least one of them among the tick's rows.
void AssignMethod::bias_update(std::int64_t now_ms, const std::set<std::string>& rows, Output& out) {
    const BiasParams& bp = *pack_.bias;
    const bool timed = pack_.time_offset_sigma_ms.has_value();
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
                const PairUpdate u = update_pair(bias_state(pair), predict(es, now_ms), predict(et, now_ms), bp,
                                                 pack_.time_offset_sigma_ms);
                if (u.accepted) bias_[pair] = u.state;

                // 4. Trace, with the state after step 3.
                const BiasState& st = u.state;
                Json rec = Json::make_object();
                rec["stage"] = "bias";
                rec["a"] = ex.key;
                rec["b"] = ey.key;
                rec["test"] = "offset";
                rec["value"] = u.d2;
                rec["limit"] = bp.gate;
                rec["pass"] = u.accepted;
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
