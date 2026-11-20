package assign

import "math"

// Ranking (spec: Ranking).

// assignment is one choice per row: an index into the row's entries, the
// number of columns meaning alone. That is also its choice vector.
type assignment struct {
	choice []int
	total  float64
}

// totalOf is the sum of the chosen entries in ascending order of value, added
// left to right from 0. buf has room for one value per row; the sum does not
// depend on how equal values (0 and -0 included) are ordered.
func (t *table) totalOf(choice []int, buf []float64) float64 {
	vals := buf[:0]
	for i, j := range choice {
		v := t.entries[i][j].cost
		k := len(vals)
		vals = append(vals, v)
		for k > 0 && vals[k-1] > v { // insertion sort: a handful of rows
			vals[k] = vals[k-1]
			k--
		}
		vals[k] = v
	}
	sum := 0.0
	for _, v := range vals {
		sum = sum + v
	}
	return sum
}

// ranked returns the first k assignments in the Ranking order: total ascending,
// equal totals by the smaller choice vector. Every assignment is enumerated in
// choice-vector order (rows in key order, columns in creation order, alone
// last) and kept only while it is among the k best: it goes after every kept
// assignment whose total is not above its own, which is the order a stable
// sort by total of the whole enumeration gives.
//
// Once k are kept, a branch is not entered when no assignment in it can
// rank before the k-th: when a lower bound of its exact sum (the rows
// chosen so far, plus each remaining row's smallest allowed entry), less a
// margin larger than the rounding of any binary64 sum of those values,
// is not below the k-th total. Every assignment so skipped would have
// been refused, so the result is the same as without the bound.
func (t *table) ranked(k int) []assignment {
	n, m := len(t.rows), len(t.cols)
	var best []assignment // at most k, in Ranking order
	if k <= 0 {
		return best
	}
	// minRest[i], absRest[i]: the sum over rows i.. of each row's smallest
	// allowed entry, and of each row's largest allowed |entry|.
	minRest, absRest := make([]float64, n+1), make([]float64, n+1)
	for i := n - 1; i >= 0; i-- {
		lo, hi := math.Inf(1), 0.0
		for _, e := range t.entries[i] {
			if e.ok {
				lo, hi = math.Min(lo, e.cost), math.Max(hi, math.Abs(e.cost))
			}
		}
		minRest[i], absRest[i] = minRest[i+1]+lo, absRest[i+1]+hi
	}
	// eps bounds the relative rounding of n-term sums (well above (n+2)·2⁻⁵³).
	eps := float64(8*(n+4)) * 0x1p-52
	choice := make([]int, n)
	used := make([]bool, m)
	buf := make([]float64, n)
	var rec func(i int, sum, abs float64)
	rec = func(i int, sum, abs float64) {
		if len(best) == k {
			bound := sum + minRest[i]
			if bound-eps*(abs+absRest[i]+math.Abs(bound)) >= best[k-1].total {
				return // nothing below ranks before the k-th
			}
		}
		if i == n {
			total := t.totalOf(choice, buf)
			if len(best) == k && !(total < best[k-1].total) {
				return // ranks after all k kept
			}
			pos := len(best)
			for pos > 0 && total < best[pos-1].total {
				pos--
			}
			a := assignment{append([]int(nil), choice...), total}
			if len(best) < k {
				best = append(best, assignment{})
			}
			copy(best[pos+1:], best[pos:len(best)-1])
			best[pos] = a
			return
		}
		for j := 0; j <= m; j++ {
			e := t.entries[i][j]
			if !e.ok || (j < m && used[j]) {
				continue
			}
			choice[i] = j
			if j < m {
				used[j] = true
			}
			rec(i+1, sum+e.cost, abs+math.Abs(e.cost))
			if j < m {
				used[j] = false
			}
		}
	}
	rec(0, 0, 0)
	return best
}
