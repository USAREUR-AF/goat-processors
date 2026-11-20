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
    assignment of finite cost exists.

    The scan visits the columns not yet in the tree in ascending order, as
    the textbook loop does, so ties resolve the same way; a forbidden entry
    never lowers minv, so its arithmetic is skipped. The potentials of the
    tree's columns are updated in the order the columns joined it: each
    belongs to a different row, so the order changes no value."""
    n = len(cost)
    if n == 0:
        return []
    m = len(cost[0])
    u = [0.0] * (n + 1)
    v = [0.0] * (m + 1)
    p = [0] * (m + 1)
    way = [0] * (m + 1)
    columns = range(1, m + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minv = [INF] * (m + 1)
        free = list(columns)
        tree = [0]
        while True:
            i0 = p[j0]
            row = cost[i0 - 1]
            ui = u[i0]
            delta = INF
            j1 = -1
            for j in free:
                c = row[j - 1]
                if c != INF:
                    cur = c - ui - v[j]
                    if cur < minv[j]:
                        minv[j] = cur
                        way[j] = j0
                mj = minv[j]
                if mj < delta:
                    delta = mj
                    j1 = j
            if j1 == -1:
                return None
            for j in tree:
                u[p[j]] += delta
                v[j] -= delta
            for j in free:
                minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
            free.remove(j1)
            tree.append(j1)
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
    """The matrix with the entries `forbidden` and, for each fixed (i, j),
    the rest of row i and of column j set to INF. Every step only sets
    entries to INF, so the result depends on the sets, not their order."""
    m = len(matrix[0]) if matrix else 0
    out = [r[:] for r in matrix]
    for i, j in forbidden:
        out[i][j] = INF
    for i, j in fixed:
        keep = out[i][j]
        row = [INF] * m
        row[j] = keep
        out[i] = row
        for ii in range(len(out)):
            if ii != i:
                out[ii][j] = INF
    return out


def _order_key(matrix, cols, c):
    return (assignment_total(matrix, cols), _choice_vector(cols, c))


class _Ranker:
    """The ranking of one cost matrix. Every subproblem is the matrix under
    a set of fixed and a set of forbidden entries; each is solved once
    (the constrained matrix, and so the exact assignment, is a function of
    the two sets) and built only then."""

    def __init__(self, matrix, c):
        self.matrix = matrix
        self.c = c
        self.solved = {}
        finite = [abs(x) for r in matrix for x in r if x != INF]
        # Rounding of any total of this matrix is far below this (n * 2**-53
        # times a sum of n entries): a bound that exceeds the best total by
        # more cannot be a total below it.
        self.slack = 1e-9 * (1.0 + len(matrix) * (max(finite) if finite else 0.0))

    def solve(self, fixed, forbidden):
        key = (frozenset(fixed), frozenset(forbidden))
        cols = self.solved.get(key, self)
        if cols is self:
            cols = min_cost_assignment(_constrained(self.matrix, fixed, forbidden))
            self.solved[key] = cols
        return cols

    def _bound_parts(self, i, fixed_row, fixed_col, forb, fixed):
        """For row i of the row-by-row fixing: the sum of the entries already
        fixed (prefix rows and rows before i) and, for every other free row,
        its two least allowed entries with their columns."""
        matrix = self.matrix
        n = len(matrix)
        taken_row = dict(fixed_row)
        taken_col = dict(fixed_col)
        for r, col in fixed:
            taken_row[r] = col
            taken_col[col] = r
        total = 0.0
        free = []
        for r in range(n):
            if r == i:
                continue
            col = taken_row.get(r)
            row = matrix[r]
            if col is not None:
                total += row[col]  # finite: fixed entries come from feasible assignments
                continue
            a = b = INF
            ja = -1
            for jj, x in enumerate(row):
                if x == INF or (r, jj) in forb or taken_col.get(jj, r) != r:
                    continue
                if x < a:
                    b, a, ja = a, x, jj
                elif x < b:
                    b = x
            free.append((a, ja, b))
        return total, free

    def _bound(self, parts, i, j):
        """A lower bound of the total of any assignment that also fixes (i, j):
        INF when none can (a free row left with no column)."""
        total, free = parts
        lb = total + self.matrix[i][j]
        for a, ja, b in free:
            lb += b if ja == j else a
        return lb

    def first(self, prefix, forbidden):
        """_first_assignment of the matrix under (prefix, forbidden): the
        first assignment in ranking order (least total, then the smallest
        choice vector), by the exact assignment and row-by-row fixing."""
        if self.solve(prefix, forbidden) is None:
            return None
        matrix, c = self.matrix, self.c
        n = len(matrix)
        fixed_row = {i: j for i, j in prefix}
        fixed_col = {j: i for i, j in prefix}
        forb = set(forbidden)
        fixed = []
        best = None
        for i in range(n):
            best = None
            fr = fixed_row.get(i)
            bound = False  # built when a second candidate needs it
            for j in list(range(c)) + [c + i]:
                # the entry of the matrix under (prefix, forbidden)
                if (matrix[i][j] == INF or (i, j) in forb or (fr is not None and fr != j)
                        or fixed_col.get(j, i) != i):
                    continue
                if best is not None:
                    if bound is False:
                        bound = self._bound_parts(i, fixed_row, fixed_col, forb, fixed)
                    if self._bound(bound, i, j) > best[0] + self.slack + 1e-9 * abs(best[0]):
                        continue  # its total cannot be below the best: not solved
                cols = self.solve(list(prefix) + fixed + [(i, j)], forbidden)
                if cols is None:
                    continue
                key = assignment_total(matrix, cols)
                if best is None or key < best[0]:
                    best = (key, j, cols)
            fixed.append((i, best[1]))
        if best is None:
            return []
        return best[2]


def _first_assignment(matrix, c):
    """The first assignment in ranking order (least total, then the smallest
    choice vector), found with the exact assignment and row-by-row fixing."""
    return _Ranker(matrix, c).first((), ())


def ranked_assignments(matrix, c, k):
    """correlate-assign.md, Ranking: the first k assignments in ranking order,
    by Murty's partition of the solution space around each one found."""
    n = len(matrix)
    ranker = _Ranker(matrix, c)
    first = ranker.first((), ())
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
            got = ranker.first(prefix, forb)
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
