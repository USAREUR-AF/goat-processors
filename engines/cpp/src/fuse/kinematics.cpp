// fuse.md "Kinematics".
#include "fuse/kinematics.hpp"

#include "trace/trace.hpp"

namespace corr::fuse {

namespace {

using trace::name_or_null;

// "inverse_variance": per axis, members in key order, sums of the inverse
// variances and of the variance-weighted values. With one member, that
// member's predicted filter.
Kinematics inverse_variance(const std::vector<Predicted>& members) {
    if (members.size() == 1) return {members[0].f, nullptr};
    Filter out;
    for (int axis = 0; axis < 2; ++axis) {
        double ip = 0, sp = 0, iv = 0, sv = 0;
        for (const Predicted& m : members) {
            const Axis& a = axis == 0 ? m.f.east : m.f.north;
            ip = ip + 1 / a.pp;
            sp = sp + a.p / a.pp;
            iv = iv + 1 / a.vv;
            sv = sv + a.v / a.vv;
        }
        Axis& r = axis == 0 ? out.east : out.north;
        r.pp = 1 / ip;
        r.p = r.pp * sp;
        r.vv = 1 / iv;
        r.v = r.vv * sv;
    }
    return {out, nullptr};
}

// "covariance_intersection": fold the members in key order into X, which
// starts as the first member; each fold is one `intersect` trace record.
Kinematics covariance_intersection(const Group& g, const std::vector<Predicted>& members, Output& out) {
    Filter x = members[0].f;
    for (size_t k = 1; k < members.size(); ++k) {
        const Filter& y = members[k].f;

        // "Weight", steps 1 to 5.
        double ae = 1 / y.east.pp, an = 1 / y.north.pp;
        double de = 1 / x.east.pp - ae, dn = 1 / x.north.pp - an;
        double c2 = de * dn;
        double c1 = ae * dn + an * de;
        double w;
        if (c2 < 0) {
            w = -c1 / (2 * c2);
            if (w < 0) w = 0;
            if (w > 1) w = 1;
        } else if (c1 + c2 > 0) {
            w = 1;
        } else if (c1 + c2 < 0) {
            w = 0;
        } else {
            w = 0.5;
        }

        Json rec = Json::make_object();
        rec["stage"] = "intersect";
        rec["group"] = name_or_null(g.name);
        rec["member"] = members[k].entity->key;
        rec["value"] = w;
        out.trace.push(std::move(rec));

        // "Fold": w = 1 keeps X, w = 0 takes Y, otherwise per axis.
        if (w == 1) continue;
        if (w == 0) {
            x = y;
            continue;
        }
        Filter folded;
        for (int axis = 0; axis < 2; ++axis) {
            const Axis& xa = axis == 0 ? x.east : x.north;
            const Axis& ya = axis == 0 ? y.east : y.north;
            Axis& r = axis == 0 ? folded.east : folded.north;
            double a = w / xa.pp, b = (1 - w) / ya.pp;
            r.pp = 1 / (a + b);
            r.p = r.pp * (a * xa.p + b * ya.p);
            double c = w / xa.vv, d = (1 - w) / ya.vv;
            r.vv = 1 / (c + d);
            r.v = r.vv * (c * xa.v + d * ya.v);
        }
        x = folded;
    }
    return {x, nullptr};
}

} // namespace

Kinematics combine(Method method, const Group& g, const std::vector<Predicted>& members,
                   const std::vector<std::string>& sources, Output& out) {
    switch (method) {
        case Method::InverseVariance:
            return inverse_variance(members);
        case Method::CovarianceIntersection:
            return covariance_intersection(g, members, out);
        case Method::Best: {
            // The member with the smallest var, ties to key order.
            const Predicted* w = &members[0];
            for (const Predicted& m : members)
                if (m.var() < w->var()) w = &m;
            return {w->f, w->entity};
        }
        case Method::Priority: {
            // The member with the smallest rank, ties to key order.
            const Predicted* w = &members[0];
            for (const Predicted& m : members)
                if (rank_order(sources, m.entity->source) < rank_order(sources, w->entity->source)) w = &m;
            return {w->f, w->entity};
        }
        case Method::Latest: {
            // The member with the greatest last_time_ms, ties to key order.
            const Predicted* w = &members[0];
            for (const Predicted& m : members)
                if (m.entity->last_time_ms > w->entity->last_time_ms) w = &m;
            return {w->f, w->entity};
        }
    }
    return {};
}

} // namespace corr::fuse
