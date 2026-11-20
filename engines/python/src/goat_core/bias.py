"""Sensor bias and time offset per pair of sources (spec/correlate-assign.md,
Sensor bias). A pair's state is
[[o_east, var, weight_east], [o_north, var, weight_north], pairs] and, with
time_offset, then tau (s) and the eight sums. Pure functions: each returns a
new state."""


def prior(prm, timed):
    """The state of a pair before its first accepted residual."""
    v = prm["sigma_m"] ** 2
    st = [[0.0, v, 0.0], [0.0, v, 0.0], 0]
    if timed:
        st += [0.0, [0.0] * 8]
    return st


def offset(st, prm, timed, forward, vel):
    """Per axis (shift, variance) that moves a position of one source, with
    velocity vel, into the frame of the other: the pair estimate (sign +1
    when `forward`, from the lower source id to the higher), or 0 with the
    prior variance when the pair has no state."""
    if st is None:
        v = prm["sigma_m"] ** 2
        return ((0.0, v), (0.0, v))
    sign = 1.0 if forward else -1.0
    out = []
    for x in (0, 1):
        o = st[x][0]
        if timed:
            o = o - vel[x] * st[3]
        out.append((sign * o, st[x][1]))
    return tuple(out)


def shifted(pr, off):
    """A prediction (east, north) moved by an offset: shift added to p,
    variance to pp."""
    return tuple((x[0] + o[0], x[1], x[2] + o[1]) + tuple(x[3:]) for x, o in zip(pr, off))


def residual(st, pl, ph, timed):
    """The residual of one pair: predictions pl (lower source) and ph.
    Returns (d2, ys, rs, vs): its test value and, per axis, the difference,
    its variance and the mean velocity."""
    ys, rs, vs = [], [], []
    d2 = 0.0
    for x in (0, 1):
        y = ph[x][0] - pl[x][0]
        r = pl[x][2] + ph[x][2]
        vx = (pl[x][1] + ph[x][1]) / 2
        ys.append(y)
        rs.append(r)
        vs.append(vx)
        want = st[x][0] - vx * st[3] if timed else st[x][0]
        d2 += (y - want) ** 2 / (st[x][1] + r)
    return d2, ys, rs, vs


def _variance(prm, n):
    var = prm["sigma_m"] ** 2 / (n + 1)
    floor2 = prm["floor_m"] ** 2
    return floor2 if var < floor2 else var


def update(st, ys, rs, prm):
    """One accepted residual, without time offset: a weighted running mean."""
    n = st[2] + 1
    pv = _variance(prm, n)
    new = []
    for x in (0, 1):
        w = 1.0 / rs[x]
        ws = st[x][2] + w
        new.append([st[x][0] + (w / ws) * (ys[x] - st[x][0]), pv, ws])
    return [new[0], new[1], n]


def time_fit(st, ys, rs, vs, prm, time_offset_sigma_ms):
    """Time offset: add one pair to the sums and solve for the offsets
    o east, o north and the time offset."""
    n = st[2] + 1
    var = _variance(prm, n)
    S = list(st[4])
    we, wn = 1.0 / rs[0], 1.0 / rs[1]
    ve, vn = vs[0], vs[1]
    S[0] += we
    S[1] += wn
    S[2] += we * ve
    S[3] += wn * vn
    S[4] += we * ve * ve + wn * vn * vn
    S[5] += we * ys[0]
    S[6] += wn * ys[1]
    S[7] += we * ve * ys[0] + wn * vn * ys[1]
    po = 1.0 / prm["sigma_m"] ** 2
    pt = 1.0 / (time_offset_sigma_ms / 1000.0) ** 2
    a11 = po + S[0]
    a22 = po + S[1]
    a13 = -S[2]
    a23 = -S[3]
    a33 = pt + S[4]
    b1, b2, b3 = S[5], S[6], -S[7]
    tau = (b3 - a13 * b1 / a11 - a23 * b2 / a22) / (a33 - a13 * a13 / a11 - a23 * a23 / a22)
    oe = (b1 - a13 * tau) / a11
    on = (b2 - a23 * tau) / a22
    return [[oe, var, S[0]], [on, var, S[1]], n, tau, S]
