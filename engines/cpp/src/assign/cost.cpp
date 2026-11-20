// correlate-assign.md "Assignment of one source": Fused estimate, Cost.
#include "assign/cost.hpp"

namespace corr::correlate {

Filter fused_estimate(const std::vector<Filter>& predictions) {
    double sp[2] = {0, 0}, spp[2] = {0, 0}, sv[2] = {0, 0}, svv[2] = {0, 0};
    for (const Filter& f : predictions) {
        const Axis* ax[2] = {&f.east, &f.north};
        for (int i = 0; i < 2; ++i) {
            spp[i] = spp[i] + 1 / ax[i]->pp;
            sp[i] = sp[i] + ax[i]->p / ax[i]->pp;
            svv[i] = svv[i] + 1 / ax[i]->vv;
            sv[i] = sv[i] + ax[i]->v / ax[i]->vv;
        }
    }
    Filter out;
    Axis* ax[2] = {&out.east, &out.north};
    for (int i = 0; i < 2; ++i) {
        ax[i]->pp = 1 / spp[i];
        ax[i]->p = ax[i]->pp * sp[i];
        ax[i]->vv = 1 / svv[i];
        ax[i]->v = ax[i]->vv * sv[i];
        ax[i]->pv = 0;
    }
    return out;
}

double entry_cost(const Entity& a, const Filter& f, bool keeps, double keep_bonus) {
    double pp_ae = a.filter.east.pp + a.timing.east, pp_an = a.filter.north.pp + a.timing.north;
    double de = a.filter.east.p - f.east.p, dn = a.filter.north.p - f.north.p;
    double d2 = de * de / (pp_ae + f.east.pp) + dn * dn / (pp_an + f.north.pp);
    if (keeps) d2 = d2 - keep_bonus;
    return d2;
}

} // namespace corr::correlate
