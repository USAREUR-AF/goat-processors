"""Scores of one engine on one scenario, and their aggregation.

Every number here is defined, with its formula, in README.md ("Scores").
"""

import math

from scenarios import to_plane

GOSPA_C = 500.0      # cut-off distance, m
GOSPA_P = 2          # order
MIN_EPISODE_S = 10   # an episode shorter than this is not counted as a missed merge
MATCH_M = 500.0      # IDF1 and SIAP: an output track is on an object when within this distance, m


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
    # IDF1: ticks each (object, output track) pair is within MATCH_M; totals of both sides.
    co = {}
    id_gt = id_hyp = 0
    # SIAP: per-tick sums, and per object its current best track and run lengths.
    siap = dict(nt=0, jt=0, na=0, n=0, pa=0.0, changes=0, tracked_s=0.0, ls=0, present=0)
    best_prev, run, longest, present_ticks = {}, {}, {}, {}
    prev_now = None

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

        # IDF1 and SIAP use the same two sets as GOSPA, with their labels.
        H = [(tr["system"], to_plane(tr["lat"], tr["lon"])) for tr in tracks
             if tr["lat"] is not None and any(m in live_set for m in tr["members"])]
        G = [(o, to_plane(*truth["objects"][o]["pos"][ti])) for o in sorted(by_obj)
             if truth["objects"][o]["pos"][ti] is not None]
        id_gt += len(G)
        id_hyp += len(H)
        near = {}                       # object -> tracks within MATCH_M whose nearest object it is
        on = 0                          # output tracks within MATCH_M of some object
        for h, hp in H:
            best = None
            for o, gp in G:
                d = math.hypot(hp[0] - gp[0], hp[1] - gp[1])
                if d < MATCH_M:
                    co[(o, h)] = co.get((o, h), 0) + 1
                    if best is None or d < best[0]:
                        best = (d, o)
            if best is not None:
                on += 1
                siap["pa"] += best[0]
                near.setdefault(best[1], []).append((best[0], h))
        dt = (now - prev_now) / 1000.0 if prev_now is not None else 0.0
        siap["nt"] += len(G)
        siap["n"] += len(H)
        siap["na"] += on
        siap["jt"] += len(near)
        # Continuity: an object keeps the track it had while that track stays within
        # MATCH_M (as Stone Soup's track-to-truth association); objects and tracks
        # left over are paired by the one-to-one assignment of least total distance.
        own = {}
        dist = {(o, h): math.hypot(hp[0] - gp[0], hp[1] - gp[1]) for o, gp in G for h, hp in H}
        taken = set()
        for o, _ in G:
            h = best_prev.get(o)
            if h is not None and h not in taken and dist.get((o, h), MATCH_M) < MATCH_M:
                own[o] = h
                taken.add(h)
        G2 = [o for o, _ in G if o not in own]
        H2 = [h for h, _ in H if h not in taken]
        if G2 and H2:
            nn = max(len(G2), len(H2))
            cm = [[MATCH_M] * nn for _ in range(nn)]
            for i, o in enumerate(G2):
                for j, h in enumerate(H2):
                    cm[i][j] = min(dist[(o, h)], MATCH_M)
            for i, j in enumerate(hungarian(cm)):
                if i < len(G2) and j < len(H2) and cm[i][j] < MATCH_M:
                    own[G2[i]] = H2[j]
        for o, _ in G:
            present_ticks[o] = present_ticks.get(o, 0) + 1
            if o in own:
                h = own[o]
                was = best_prev.get(o)
                if was is not None:
                    siap["tracked_s"] += dt
                    if was != h:
                        siap["changes"] += 1
                run[o] = run.get(o, 0) + 1 if was == h else 1
                longest[o] = max(longest.get(o, 0), run[o])
                best_prev[o] = h
            else:
                best_prev[o] = None
                run[o] = 0
        here = {o for o, _ in G}
        for o in list(best_prev):
            if o not in here:
                best_prev[o] = None
                run[o] = 0
        prev_now = now

    closed.extend(episodes.values())
    siap["ls"] = sum(longest.values())
    siap["present"] = sum(present_ticks.values())
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
        "id_tp": id_matches(co), "id_gt": id_gt, "id_hyp": id_hyp,
        "siap_nt": siap["nt"], "siap_jt": siap["jt"], "siap_na": siap["na"], "siap_n": siap["n"],
        "siap_pa": siap["pa"], "siap_changes": siap["changes"], "siap_tracked_s": siap["tracked_s"],
        "siap_ls": siap["ls"], "siap_present": siap["present"],
    }


def id_matches(co):
    """IDF1's IDTP: the largest total of co-located ticks over one-to-one object-track pairs."""
    objs = sorted({o for o, _ in co})
    hyps = sorted({h for _, h in co})
    if not objs:
        return 0
    n = max(len(objs), len(hyps))
    top = max(co.values())
    cost = [[float(top - co.get((objs[i], hyps[j]), 0)) if i < len(objs) and j < len(hyps) else float(top)
             for j in range(n)] for i in range(n)]
    match = hungarian(cost)
    return sum(co.get((objs[i], hyps[j]), 0) for i, j in enumerate(match) if i < len(objs) and j < len(hyps))


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
        "idf1": 2 * s["id_tp"] / (s["id_gt"] + s["id_hyp"]) if s.get("id_gt", 0) + s.get("id_hyp", 0) else None,
        "idp": s["id_tp"] / s["id_hyp"] if s.get("id_hyp") else None,
        "idr": s["id_tp"] / s["id_gt"] if s.get("id_gt") else None,
        "completeness": s["siap_jt"] / s["siap_nt"] if s.get("siap_nt") else None,
        "ambiguity": s["siap_na"] / s["siap_jt"] if s.get("siap_jt") else None,
        "spuriousness": (s["siap_n"] - s["siap_na"]) / s["siap_n"] if s.get("siap_n") else None,
        "siap_pa_m": s["siap_pa"] / s["siap_na"] if s.get("siap_na") else None,
        "track_changes_per_min": 60.0 * s["siap_changes"] / s["siap_tracked_s"] if s.get("siap_tracked_s") else None,
        "longest_segment": s["siap_ls"] / s["siap_present"] if s.get("siap_present") else None,
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
