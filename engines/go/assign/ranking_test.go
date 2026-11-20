package assign

import (
	"fmt"
	"math"
	"sort"
	"testing"
)

// TestRankedOrder checks ranked() on deterministic pseudo-random tables shaped
// like the method's (columns plus one alone cell per row, some forbidden):
// every assignment is valid, the list follows the Ranking order strictly, and
// nothing left out ranks before the last one kept.
func TestRankedOrder(t *testing.T) {
	seed := uint64(12345)
	rnd := func() float64 {
		seed = seed*6364136223846793005 + 1442695040888963407
		return float64(seed>>11) / float64(1<<53)
	}
	before := func(x, y assignment) bool {
		if x.total != y.total {
			return x.total < y.total
		}
		for i := range x.choice {
			if x.choice[i] != y.choice[i] {
				return x.choice[i] < y.choice[i]
			}
		}
		return false
	}
	for trial := 0; trial < 2000; trial++ {
		n, m := 1+int(rnd()*4), int(rnd()*5)
		tb := &table{rows: make([]string, n), cols: make([]string, m)}
		for i := 0; i < n; i++ {
			row := make([]entry, m+1)
			for j := 0; j < m; j++ {
				// Coarse values make equal totals common.
				row[j] = entry{float64(int(rnd()*4)) - 1, rnd() < 0.7}
			}
			row[m] = entry{9.21 - 2*float64(int(rnd()*2)), true}
			tb.entries = append(tb.entries, row)
		}
		all := tb.ranked(math.MaxInt)
		k := 1 + int(rnd()*4)
		got := tb.ranked(k)
		if len(got) != min(k, len(all)) {
			t.Fatalf("trial %d: %d assignments, want %d", trial, len(got), min(k, len(all)))
		}
		for i, a := range all {
			used := map[int]bool{}
			for r, j := range a.choice {
				if !tb.entries[r][j].ok || (j < m && used[j]) {
					t.Fatalf("trial %d: invalid assignment %v", trial, a.choice)
				}
				used[j] = j < m
			}
			if i > 0 && !before(all[i-1], a) {
				t.Fatalf("trial %d: %v ranks after %v", trial, all[i-1], a)
			}
		}
		for i := range got {
			if got[i].total != all[i].total {
				t.Fatalf("trial %d: rank %d differs", trial, i)
			}
		}
	}
}

// rankedReference is the Ranking by its definition: every assignment in
// choice-vector order, then a stable sort by total, then the first k.
func rankedReference(t *table, k int) []assignment {
	n, m := len(t.rows), len(t.cols)
	var all []assignment
	choice := make([]int, n)
	used := make([]bool, m)
	var rec func(i int)
	rec = func(i int) {
		if i == n {
			vals := make([]float64, n)
			for r, j := range choice {
				vals[r] = t.entries[r][j].cost
			}
			sort.Float64s(vals)
			sum := 0.0
			for _, v := range vals {
				sum = sum + v
			}
			all = append(all, assignment{append([]int(nil), choice...), sum})
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

// TestRankedMatchesReference: the bounded enumeration gives exactly the
// reference's assignments, in its order, on random tables with many ties.
func TestRankedMatchesReference(t *testing.T) {
	seed := uint64(777)
	rnd := func() float64 {
		seed = seed*6364136223846793005 + 1442695040888963407
		return float64(seed>>11) / float64(1<<53)
	}
	for trial := 0; trial < 2400; trial++ {
		n, m := 1+int(rnd()*5), int(rnd()*6)
		tb := &table{rows: make([]string, n), cols: make([]string, m)}
		for i := 0; i < n; i++ {
			row := make([]entry, m+1)
			for j := 0; j < m; j++ {
				v := float64(int(rnd()*3)) - 1 + []float64{0, 0.1, 0.2, 0.30000000000000004}[int(rnd()*4)]
				if trial%3 == 0 { // magnitudes whose sums round
					v = []float64{1e16, -1e16, 1, -1, 3, 1e-300, 4.5e15}[int(rnd()*7)]
				}
				row[j] = entry{v, rnd() < 0.75}
			}
			row[m] = entry{9.21 - 2*float64(int(rnd()*2)), true}
			tb.entries = append(tb.entries, row)
		}
		for _, k := range []int{0, 1, 2, 3, 5, 1000} {
			got, want := tb.ranked(k), rankedReference(tb, k)
			if len(got) != len(want) {
				t.Fatalf("trial %d k %d: %d assignments, want %d", trial, k, len(got), len(want))
			}
			for i := range want {
				if got[i].total != want[i].total || fmt.Sprint(got[i].choice) != fmt.Sprint(want[i].choice) {
					t.Fatalf("trial %d k %d rank %d: %v, want %v", trial, k, i, got[i], want[i])
				}
			}
		}
	}
}
