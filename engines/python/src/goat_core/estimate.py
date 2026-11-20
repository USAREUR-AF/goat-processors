"""The per-entity track estimate: a constant-velocity Kalman filter run as
two axes, and the two-model filter.

spec/correlate.md, Track estimate and Two-model filter (spec/fuse.md and
spec/quality.md use the same one-model filter). An axis is the list
[p, v, pp, pv, vv]. Pure functions: every one returns new values."""

import math

MODELS = ("quiet", "maneuver")


def predict_axis(a, dt, q):
    """Track estimate, step 1: predict one axis dt seconds (may be negative)."""
    p, v, pp, pv, vv = a
    return [p + v * dt,
            v,
            pp + 2 * dt * pv + dt * dt * vv + q * dt ** 4 / 4,
            pv + dt * vv + q * dt ** 3 / 2,
            vv + q * dt * dt]


def pos_step(a, z, r):
    """Track estimate, step 2: position update; returns the new axis, the
    innovation y and its variance s."""
    p, v, pp, pv, vv = a
    s = pp + r
    k1 = pp / s
    k2 = pv / s
    y = z - p
    return [p + k1 * y, v + k2 * y, (1 - k1) * pp, (1 - k1) * pv, vv - k2 * pv], y, s


def vel_step(a, z, r):
    """Track estimate, step 3: velocity update; returns the new axis, the
    innovation y and its variance s."""
    p, v, pp, pv, vv = a
    s = vv + r
    k1 = pv / s
    k2 = vv / s
    y = z - v
    return [p + k1 * y, v + k2 * y, pp - k1 * pv, (1 - k2) * pv, (1 - k2) * vv], y, s


def pos_update(a, z, r):
    return pos_step(a, z, r)[0]


def vel_update(a, z, r):
    return vel_step(a, z, r)[0]


def first_axes(e, n, re_, rn_, vel, filt):
    """Track estimate, first report: the (east, north) axes."""
    vv = (filt["vel_sigma_ms"] if vel else filt["unknown_vel_ms"]) ** 2
    return ([e, vel[0] if vel else 0.0, re_, 0.0, vv],
            [n, vel[1] if vel else 0.0, rn_, 0.0, vv])


def update_axes(east, north, dt, q, e, n, re_, rn_, vel, rv):
    """Track estimate, later reports: predict, position update and, with a
    measured velocity, velocity update, on both axes."""
    east = pos_update(predict_axis(east, dt, q), e, re_)
    north = pos_update(predict_axis(north, dt, q), n, rn_)
    if vel:
        east = vel_update(east, vel[0], rv)
        north = vel_update(north, vel[1], rv)
    return east, north


def blend(a1, a2, w1, w2):
    """Two-model filter: the weighted combination of two axes, with the
    spread of the means added to the covariance."""
    p1, v1, pp1, pv1, vv1 = a1
    p2, v2, pp2, pv2, vv2 = a2
    p = w1 * p1 + w2 * p2
    v = w1 * v1 + w2 * v2
    dp1, dv1, dp2, dv2 = p1 - p, v1 - v, p2 - p, v2 - v
    return [p, v,
            w1 * (pp1 + dp1 * dp1) + w2 * (pp2 + dp2 * dp2),
            w1 * (pv1 + dp1 * dv1) + w2 * (pv2 + dp2 * dv2),
            w1 * (vv1 + dv1 * dv1) + w2 * (vv2 + dv2 * dv2)]


def transition(man, dt):
    """Two-model filter: switching probabilities over dt seconds, t[i][j]
    from model i to model j."""
    a, b = man["p_enter"], man["p_leave"]
    s = a + b
    lam = math.pow(1.0 - s, dt)
    t12 = a / s * (1.0 - lam)
    t21 = b / s * (1.0 - lam)
    return [[1.0 - t12, t12], [t21, 1.0 - t21]]


def first_mode(man):
    """Two-model filter, first report: the stationary mode probabilities."""
    a, b = man["p_enter"], man["p_leave"]
    return [b / (a + b), a / (a + b)]


def predict_models(models, mode, dt, q):
    """Two-model filter, prediction: each model predicted with its own q,
    combined by the mode probabilities. Returns (east, north)."""
    pr = [(predict_axis(m[0], dt, q[j]), predict_axis(m[1], dt, q[j]))
          for j, m in enumerate(models)]
    return (blend(pr[0][0], pr[1][0], mode[0], mode[1]),
            blend(pr[0][1], pr[1][1], mode[0], mode[1]))


def two_model_update(models, mode, man, q, dt, e, n, r, vel, rv):
    """Two-model filter, later reports: mixing, per-model predict and update,
    likelihood, mode probability, combination. Returns
    (models, mode, east, north, likelihoods)."""
    t = transition(man, dt)
    mu = mode
    c = [t[0][j] * mu[0] + t[1][j] * mu[1] for j in (0, 1)]
    mixed = []
    for j in (0, 1):
        if c[j] == 0:
            mixed.append(models[j])
            continue
        w1 = t[0][j] * mu[0] / c[j]
        w2 = t[1][j] * mu[1] / c[j]
        mixed.append([blend(models[0][x], models[1][x], w1, w2) for x in (0, 1)])
    new_models, lam = [], []
    for j in (0, 1):
        east = predict_axis(mixed[j][0], dt, q[j])
        north = predict_axis(mixed[j][1], dt, q[j])
        terms = []
        east, y, s = pos_step(east, e, r[0])
        terms.append(y * y / s + math.log(s))
        north, y, s = pos_step(north, n, r[1])
        terms.append(y * y / s + math.log(s))
        if vel:
            east, y, s = vel_step(east, vel[0], rv)
            terms.append(y * y / s + math.log(s))
            north, y, s = vel_step(north, vel[1], rv)
            terms.append(y * y / s + math.log(s))
        g = 0.0
        for x in terms:
            g += x
        lam.append(-0.5 * g)
        new_models.append([east, north])
    m = max(lam[j] for j in (0, 1) if c[j] > 0)
    w = [c[j] * math.exp(lam[j] - m) if c[j] > 0 else 0.0 for j in (0, 1)]
    tot = w[0] + w[1]
    mu = [w[0] / tot, w[1] / tot]
    east = blend(new_models[0][0], new_models[1][0], mu[0], mu[1])
    north = blend(new_models[0][1], new_models[1][1], mu[0], mu[1])
    return new_models, mu, east, north, lam


def predict_out(east, north, models, mode, dt, q):
    """The prediction's (p, v, pp, vv) per axis, without the cross term, which
    an output combination does not use: the arithmetic of predict_axis and
    blend (or predict_axis alone without models, q then a number) in the same
    order, so the same values."""
    dt2 = 2 * dt
    dd = dt * dt
    d4 = dt ** 4
    if models is None:
        qa, qv = q * d4 / 4, q * dt * dt
        return [(p + v * dt, v, pp + dt2 * pv + dd * vv + qa, vv + qv)
                for p, v, pp, pv, vv in (east, north)]
    w1, w2 = mode
    (e1, n1), (e2, n2) = models
    qa1, qv1 = q[0] * d4 / 4, q[0] * dt * dt
    qa2, qv2 = q[1] * d4 / 4, q[1] * dt * dt
    out = []
    for (p1, v1, pp1, pv1, vv1), (p2, v2, pp2, pv2, vv2) in ((e1, e2), (n1, n2)):
        p1, pp1, vv1 = p1 + v1 * dt, pp1 + dt2 * pv1 + dd * vv1 + qa1, vv1 + qv1
        p2, pp2, vv2 = p2 + v2 * dt, pp2 + dt2 * pv2 + dd * vv2 + qa2, vv2 + qv2
        p = w1 * p1 + w2 * p2
        v = w1 * v1 + w2 * v2
        dp1, dv1, dp2, dv2 = p1 - p, v1 - v, p2 - p, v2 - v
        out.append((p, v, w1 * (pp1 + dp1 * dp1) + w2 * (pp2 + dp2 * dp2),
                    w1 * (vv1 + dv1 * dv1) + w2 * (vv2 + dv2 * dv2)))
    return out


def with_variance(pr, add):
    """(east, north) prediction with add[x] added to pp on each axis; the
    same tuple when nothing is added."""
    if add == (0.0, 0.0):
        return pr
    return tuple((x[0], x[1], x[2] + tv) + tuple(x[3:]) for x, tv in zip(pr, add))


def inverse_variance(preds):
    """The inverse-variance combination of predictions, each (east, north):
    per axis [p, v, pp, 0, vv], the sums taken in the order given
    (spec/correlate-assign.md, Output and Cost; spec/fuse.md, inverse_variance)."""
    out = []
    for ax in (0, 1):
        ip = sp = iv = sv = 0.0
        for pr in preds:
            a = pr[ax]
            ip += 1.0 / a[2]
            sp += a[0] / a[2]
            iv += 1.0 / a[4]
            sv += a[1] / a[4]
        pp = 1.0 / ip
        vv = 1.0 / iv
        out.append([pp * sp, vv * sv, pp, 0.0, vv])
    return out
