package assign

import (
	"sort"
)

// Ranking (spec: Ranking).

// assignment is one choice per row: an index into the row's entries, the
// number of columns meaning alone. That is also its choice vector.
type assignment struct {
	choice []int
	total  float64
}

// totalOf is the sum of the chosen entries in ascending order of value, added
// left to right from 0.
func (t *table) totalOf(choice []int) float64 {
	vals := make([]float64, len(choice))
	for i, j := range choice {
		vals[i] = t.entries[i][j].cost
	}
	sort.Float64s(vals)
	sum := 0.0
	for _, v := range vals {
		sum = sum + v
	}
	return sum
}

// ranked returns the first k assignments in the Ranking order: total ascending,
// equal totals by the smaller choice vector. Every assignment is enumerated in
// choice-vector order (rows in key order, columns in creation order, alone
// last), then a stable sort by total keeps that order among equal totals.
func (t *table) ranked(k int) []assignment {
	n, m := len(t.rows), len(t.cols)
	var all []assignment
	choice := make([]int, n)
	used := make([]bool, m)
	var rec func(i int)
	rec = func(i int) {
		if i == n {
			c := append([]int(nil), choice...)
			all = append(all, assignment{c, t.totalOf(c)})
			return
		}
		for j := 0; j <= m; j++ {
			if !t.entries[i][j].ok || (j < m && used[j]) {
				continue
			}
			choice[i] = j
			if j < m {
				used[j] = true
			}
			rec(i + 1)
			if j < m {
				used[j] = false
			}
		}
	}
	rec(0)
	sort.SliceStable(all, func(a, b int) bool { return all[a].total < all[b].total })
	if len(all) > k {
		all = all[:k]
	}
	return all
}
