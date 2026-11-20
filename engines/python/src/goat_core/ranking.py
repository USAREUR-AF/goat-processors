"""The assignment of one source and its ranking (spec/correlate-assign.md,
Assignment of one source, step 3, and Ranking): the exact minimum-cost
assignment (shortest augmenting path with potentials) and Murty's
partition for the next best ones. Pure functions of the cost matrix."""

INF = float("inf")


def min_cost_assignment(cost):
    """Exact minimum-cost assignment of every row to a distinct column.

    `cost` is a list of rows, each a list of column costs (INF = forbidden),
    with at least as many columns as rows. Shortest augmenting path
    (Hungarian, potentials). Returns the column of each row, or None when no
    assignment of finite cost exists."""
    n = len(cost)
    if n == 0:
        return []
    m = len(cost[0])
    u = [0.0] * (n + 1)
    v = [0.0] * (m + 1)
    p = [0] * (m + 1)
    way = [0] * (m + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minv = [INF] * (m + 1)
        used = [False] * (m + 1)
        while True:
            used[j0] = True
            i0 = p[j0]
            delta = INF
            j1 = -1
            for j in range(1, m + 1):
                if not used[j]:
                    c = cost[i0 - 1][j - 1]
                    cur = INF if c == INF else c - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j] = cur
                        way[j] = j0
                    if minv[j] < delta:
                        delta = minv[j]
                        j1 = j
            if j1 == -1:
                return None
            for j in range(m + 1):
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
    out = [None] * n
    for j in range(1, m + 1):
        if p[j]:
            out[p[j] - 1] = j - 1
    return out


def assignment_total(matrix, cols):
    """correlate-assign.md, Ranking: the chosen entries in ascending order of
    value, added left to right from 0."""
    t = 0.0
    for x in sorted(matrix[i][j] for i, j in enumerate(cols)):
        t += x
    return t


def _choice_vector(cols, c):
    """Column index per row; every alone column counts as c, after the system columns."""
    return [j if j < c else c for j in cols]


def _constrained(matrix, fixed, forbidden):
    out = [list(r) for r in matrix]
    for i, j in forbidden:
        out[i][j] = INF
    for i, j in fixed:
        for jj in range(len(out[i])):
            if jj != j:
                out[i][jj] = INF
        for ii in range(len(out)):
            if ii != i:
                out[ii][j] = INF
    return out


def _order_key(matrix, cols, c):
    return (assignment_total(matrix, cols), _choice_vector(cols, c))


def _first_assignment(matrix, c):
    """The first assignment in ranking order (least total, then the smallest
    choice vector), found with the exact assignment and row-by-row fixing."""
    if min_cost_assignment(matrix) is None:
        return None
    n = len(matrix)
    fixed = []
    best = None
    for i in range(n):
        best = None
        cands = list(range(c)) + [c + i]
        for j in cands:
            if matrix[i][j] == INF:
                continue
            cols = min_cost_assignment(_constrained(matrix, fixed + [(i, j)], ()))
            if cols is None:
                continue
            key = _order_key(matrix, cols, c)
            if best is None or key[0] < best[0][0]:
                best = (key, j, cols)
        fixed.append((i, best[1]))
    if best is None:
        return []
    return best[2]


def ranked_assignments(matrix, c, k):
    """correlate-assign.md, Ranking: the first k assignments in ranking order,
    by Murty's partition of the solution space around each one found."""
    n = len(matrix)
    first = _first_assignment(matrix, c)
    if first is None:
        return []
    out = [first]
    queue = []

    def partition(cols, fixed, forbidden):
        fixed_rows = {i for i, _ in fixed}
        prefix = list(fixed)
        for i in range(n):
            if i in fixed_rows:
                continue
            forb = list(forbidden) + [(i, cols[i])]
            sub = _constrained(matrix, prefix, forb)
            got = _first_assignment(sub, c)
            if got is not None:
                queue.append((_order_key(matrix, got, c), got, list(prefix), forb))
            prefix.append((i, cols[i]))

    partition(first, [], [])
    while len(out) < k and queue:
        queue.sort(key=lambda e: e[0])
        _, cols, fixed, forbidden = queue.pop(0)
        out.append(cols)
        partition(cols, fixed, forbidden)
    return out
