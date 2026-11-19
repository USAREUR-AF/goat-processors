package correlator

import (
	"math"
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
