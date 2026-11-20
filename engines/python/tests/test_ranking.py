"""Unit tests of goat_core.ranking (spec/correlate-assign.md, Assignment of
one source and Ranking), against brute force on seeded random matrices."""

import itertools
import random
import unittest

from goat_core.ranking import INF, _first_assignment, assignment_total, min_cost_assignment, ranked_assignments


def brute(matrix, c):
    """Every finite assignment, in ranking order (total, then choice vector)."""
    n = len(matrix)
    out = []
    for cols in itertools.permutations(range(len(matrix[0])), n):
        if any(matrix[i][j] == INF for i, j in enumerate(cols)):
            continue
        choice = [j if j < c else c for j in cols]
        out.append((assignment_total(matrix, list(cols)), choice, list(cols)))
    out.sort(key=lambda e: (e[0], e[1]))
    return out


def random_matrix(rng, n, c, new_cost=5.0):
    """n rows, c system columns, then the n alone columns (diagonal)."""
    m = []
    for i in range(n):
        row = [INF if rng.random() < 0.3 else float(rng.randint(0, 6)) for _ in range(c)]
        row += [new_cost if j == i else INF for j in range(n)]
        m.append(row)
    return m


class MinCost(unittest.TestCase):
    def test_small(self):
        self.assertEqual(min_cost_assignment([]), [])
        self.assertEqual(min_cost_assignment([[1.0, 2.0], [2.0, 1.0]]), [0, 1])
        self.assertEqual(min_cost_assignment([[5.0, 1.0], [1.0, 5.0]]), [1, 0])
        self.assertIsNone(min_cost_assignment([[INF, INF], [1.0, 2.0]]))

    def test_against_brute_force(self):
        rng = random.Random(7)
        for _ in range(200):
            n, c = rng.randint(1, 4), rng.randint(0, 4)
            m = random_matrix(rng, n, c)
            cols = min_cost_assignment(m)
            best = brute(m, c)[0][0]
            self.assertEqual(sum(m[i][j] for i, j in enumerate(cols)), best)

    def test_total_adds_in_ascending_order(self):
        self.assertEqual(assignment_total([[0.1, 1e16], [1e16, 0.1]], [1, 0]), 2e16)
        self.assertEqual(assignment_total([[3.0, 0], [0, 1.0]], [0, 1]), 4.0)


class Ranking(unittest.TestCase):
    def test_first_k_in_ranking_order(self):
        rng = random.Random(11)
        for _ in range(150):
            n, c = rng.randint(1, 4), rng.randint(0, 3)
            m = random_matrix(rng, n, c)
            want = brute(m, c)
            for k in (1, 2, 3, 5):
                got = ranked_assignments(m, c, k)
                self.assertEqual(len(got), min(k, len(want)))
                for g, w in zip(got, want):
                    self.assertEqual((assignment_total(m, g), [j if j < c else c for j in g]), (w[0], w[1]))

    def test_ties_go_to_the_smaller_choice_vector(self):
        m = [[1.0, 1.0, 5.0]]
        self.assertEqual(ranked_assignments(m, 2, 2), [[0], [1]])

    def test_no_rows(self):
        self.assertEqual(ranked_assignments([], 0, 3), [[]])

    def test_infeasible_and_first(self):
        self.assertEqual(ranked_assignments([[INF]], 0, 2), [])
        self.assertEqual(_first_assignment([[2.0, 1.0, 5.0]], 2), [1])

    def test_negative_entries(self):
        """Entries below 0 (a cost less the keep bonus): the bound still holds."""
        rng = random.Random(17)
        for _ in range(300):
            n, c = rng.randint(2, 5), rng.randint(1, 4)
            m = [[INF if rng.random() < 0.3 else float(rng.randint(-4, 6)) for _ in range(c)]
                 + [rng.choice([-1.0, 3.0]) if j == i else INF for j in range(n)] for i in range(n)]
            want = brute(m, c)
            got = ranked_assignments(m, c, 3)
            self.assertEqual([(assignment_total(m, g), [j if j < c else c for j in g]) for g in got],
                             [(w[0], w[1]) for w in want[:3]])

    def test_dense_forbidden(self):
        """Mostly forbidden entries: the bound meets rows with no column left."""
        rng = random.Random(13)
        for _ in range(300):
            n, c = rng.randint(2, 5), rng.randint(1, 4)
            m = [[INF if rng.random() < 0.6 else float(rng.randint(0, 9)) for _ in range(c)]
                 + [rng.choice([3.0, 9.0]) if j == i else INF for j in range(n)] for i in range(n)]
            want = brute(m, c)
            got = ranked_assignments(m, c, 4)
            self.assertEqual([(assignment_total(m, g), [j if j < c else c for j in g]) for g in got],
                             [(w[0], w[1]) for w in want[:4]])


if __name__ == "__main__":
    unittest.main()
