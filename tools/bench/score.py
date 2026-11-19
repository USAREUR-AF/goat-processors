"""Scores of one engine on one scenario, and their aggregation.

Every number here is defined, with its formula, in README.md ("Scores").
"""

import math

from scenarios import to_plane

GOSPA_C = 500.0      # cut-off distance, m
GOSPA_P = 2          # order
MIN_EPISODE_S = 10   # an episode shorter than this is not counted as a missed merge


def score(truth, vector, ticks):
    """Score one run. `ticks` maps now_ms to the list of output tracks."""
    live_ms = truth["live_ms"]
    labels = truth["labels"]
    tick_index = {t: i for i, t in enumerate(truth["ticks"])}
    last_time, obj_of = {}, {}
    tp = fp = fn = 0
    false_merges = 0
    swaps = 0
    episodes = {}          # pair -> [start_ms, first associated ms or None, last ms]
    closed = []            # finished episodes
    prev_fp = set()
    prev_label = {}        # truth object -> output label at the previous tick
    sq_err, n_err = 0.0, 0
    gospa_sum = gospa_loc = 0.0
    gospa_missed = gospa_false = 0
    n_ticks = 0

    for step, label in zip(vector["steps"], labels):
        if "ingest" in step:
            r = step["ingest"]
            key = "%s/%s" % (r["track.source_id"], r["uid"])
            last_time[key] = r["time_ms"]
            obj_of[key] = label
            continue
        now = step["tick"]
        n_ticks += 1
        tracks = ticks.get(now, [])
        live = sorted(k for k, t in last_time.items() if t >= now - live_ms)
        live_set = set(live)
        group_of, pos_of = {}, {}
        for tr in tracks:
            pos_of[tr["system"]] = (tr["lat"], tr["lon"])
            for m in tr["members"]:
                group_of.setdefault(m, tr["system"])
        out_label = {k: group_of.get(k, "alone:" + k) for k in live}

        # Pairwise association.
        now_fp = set()
        seen_pairs = set()
        for i in range(len(live)):
            a = live[i]
            for j in range(i + 1, len(live)):
                b = live[j]
                same_truth = obj_of[a] is not None and obj_of[a] == obj_of[b]
                same_out = out_label[a] == out_label[b]
                pair = (a, b)
                if same_truth and same_out:
                    tp += 1
                elif same_out:
                    fp += 1
                    now_fp.add(pair)
                    if pair not in prev_fp:
                        false_merges += 1
                elif same_truth:
                    fn += 1
                if same_truth:
                    seen_pairs.add(pair)
                    ep = episodes.get(pair)
                    if ep is None:
                        ep = episodes[pair] = [now, None, now]
                    ep[2] = now
                    if same_out and ep[1] is None:
                        ep[1] = now
        for pair in [p for p in episodes if p not in seen_pairs]:
            closed.append(episodes.pop(pair))
        prev_fp = now_fp

        # Identity of each truth object: the output track holding most of its live tracks.
        present = set(out_label.values()) | set(pos_of)
        by_obj = {}
        for k in live:
            if obj_of[k] is not None:
                by_obj.setdefault(obj_of[k], []).append(out_label[k])
        assigned = {}
        for o in sorted(by_obj):
            counts = {}
            for lab in by_obj[o]:
                counts[lab] = counts.get(lab, 0) + 1
            best = max(counts.values())
            tied = sorted(lab for lab, c in counts.items() if c == best)
            lab = prev_label[o] if prev_label.get(o) in tied else tied[0]
            assigned[o] = lab
            if o in prev_label and prev_label[o] != lab and prev_label[o] in present:
                swaps += 1
            prev_label[o] = lab

        # Fused position error of each truth object's output track.
        ti = tick_index[now]
        for o, lab in assigned.items():
            p = pos_of.get(lab)
            tpos = truth["objects"][o]["pos"][ti]
            if p is None or p[0] is None or tpos is None:
                continue
            ex, ny = to_plane(*p)
            tx, ty = to_plane(*tpos)
            sq_err += (ex - tx) ** 2 + (ny - ty) ** 2
            n_err += 1

        # GOSPA between the output tracks with a live member and the truth
        # objects with a live track.
        X = []
        for tr in tracks:
            if tr["lat"] is not None and any(m in live_set for m in tr["members"]):
                X.append(to_plane(tr["lat"], tr["lon"]))
        Y = [to_plane(*truth["objects"][o]["pos"][ti]) for o in sorted(by_obj)
             if truth["objects"][o]["pos"][ti] is not None]
        g, loc, missed, false = gospa(X, Y)
        gospa_sum += g
        gospa_loc += loc
        gospa_missed += missed
        gospa_false += false

    closed.extend(episodes.values())
    long_eps = [e for e in closed if (e[2] - e[0]) / 1000.0 >= MIN_EPISODE_S]
    missed_merges = sum(1 for e in long_eps if e[1] is None)
    tta = [(e[1] - e[0]) / 1000.0 for e in closed if e[1] is not None]
    return {
        "tp": tp, "fp": fp, "fn": fn,
        "false_merges": false_merges, "missed_merges": missed_merges, "episodes": len(long_eps),
        "swaps": swaps,
        "tta_sum": sum(tta), "tta_n": len(tta),
        "sq_err": sq_err, "n_err": n_err,
        "gospa_sum": gospa_sum, "gospa_loc": gospa_loc,
        "gospa_missed": gospa_missed, "gospa_false": gospa_false, "ticks": n_ticks,
    }


def derive(s):
    """The reported scores from summed counts (one run or many)."""
    p = s["tp"] / (s["tp"] + s["fp"]) if s["tp"] + s["fp"] else None
    r = s["tp"] / (s["tp"] + s["fn"]) if s["tp"] + s["fn"] else None
    if s["tp"] == 0:
        f1 = 0.0 if s["fp"] + s["fn"] else None
    else:
        f1 = 2 * p * r / (p + r)
    return {
        "precision": p, "recall": r, "f1": f1,
        "false_merges": s["false_merges"], "missed_merges": s["missed_merges"],
        "swaps": s["swaps"],
        "tta_s": s["tta_sum"] / s["tta_n"] if s["tta_n"] else None,
        "rms_m": math.sqrt(s["sq_err"] / s["n_err"]) if s["n_err"] else None,
        "gospa_m": s["gospa_sum"] / s["ticks"] if s["ticks"] else None,
        "gospa_loc_m": s["gospa_loc"] / s["ticks"] if s["ticks"] else None,
        "missed_per_tick": s["gospa_missed"] / s["ticks"] if s["ticks"] else None,
        "false_per_tick": s["gospa_false"] / s["ticks"] if s["ticks"] else None,
    }


def add(a, b):
    return {k: a.get(k, 0) + b[k] for k in b}


def gospa(X, Y, c=GOSPA_C, p=GOSPA_P):
    """GOSPA with alpha = 2. Returns (distance, localisation part, missed, false).

    The localisation part is (sum of d^p over assigned pairs closer than c)^(1/p).
    """
    nx, ny = len(X), len(Y)
    if nx == 0 and ny == 0:
        return 0.0, 0.0, 0, 0
    half = c ** p / 2.0
    n = nx + ny
    cost = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            if i < nx and j < ny:
                d = math.hypot(X[i][0] - Y[j][0], X[i][1] - Y[j][1])
                cost[i][j] = min(d, c) ** p
            elif i < nx or j < ny:
                cost[i][j] = half
    match = hungarian(cost)
    total = loc = 0.0
    assigned_x, assigned_y = 0, 0
    for i, j in enumerate(match):
        total += cost[i][j]
        if i < nx and j < ny and cost[i][j] < c ** p:
            loc += cost[i][j]
            assigned_x += 1
            assigned_y += 1
    false = nx - assigned_x
    missed = ny - assigned_y
    return total ** (1.0 / p), loc ** (1.0 / p), missed, false


def hungarian(cost):
    """Exact minimum-cost perfect matching of a square matrix; returns column per row."""
    n = len(cost)
    INF = float("inf")
    u = [0.0] * (n + 1)
    v = [0.0] * (n + 1)
    p = [0] * (n + 1)
    way = [0] * (n + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minv = [INF] * (n + 1)
        used = [False] * (n + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], INF, 0
            for j in range(1, n + 1):
                if not used[j]:
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j], way[j] = cur, j0
                    if minv[j] < delta:
                        delta, j1 = minv[j], j
            for j in range(n + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
            if j0 == 0:
                break
    col = [0] * n
    for j in range(1, n + 1):
        col[p[j] - 1] = j - 1
    return col
