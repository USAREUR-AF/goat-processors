package correlator

import (
	"math"
	"testing"
)

// bruteAssign returns the least total over every assignment of rows to distinct allowed columns.
func bruteAssign(cost [][]float64, allowed [][]bool) float64 {
	n, m := len(cost), len(cost[0])
	used := make([]bool, m)
	best := math.Inf(1)
	var rec func(i int, sum float64)
	rec = func(i int, sum float64) {
		if i == n {
			best = math.Min(best, sum)
			return
		}
		for j := 0; j < m; j++ {
			if !used[j] && allowed[i][j] {
				used[j] = true
				rec(i+1, sum+cost[i][j])
				used[j] = false
			}
		}
	}
	rec(0, 0)
	return best
}

// TestHungarianExact checks the solver against brute force on deterministic
// pseudo-random matrices shaped like the method's: m system columns plus one
// alone column per row, with forbidden entries.
func TestHungarianExact(t *testing.T) {
	seed := uint64(12345)
	rnd := func() float64 {
		seed = seed*6364136223846793005 + 1442695040888963407
		return float64(seed>>11) / float64(1<<53)
	}
	for trial := 0; trial < 3000; trial++ {
		n, m := 1+int(rnd()*5), int(rnd()*6)
		cost := make([][]float64, n)
		allowed := make([][]bool, n)
		for i := range cost {
			cost[i] = make([]float64, m+n)
			allowed[i] = make([]bool, m+n)
			for j := 0; j < m; j++ {
				allowed[i][j] = rnd() < 0.7
				cost[i][j] = rnd()*12 - 2
			}
			cost[i][m+i], allowed[i][m+i] = 9.21-2*float64(int(rnd()*2)), true
		}
		got := hungarian(cost, allowed)
		seen := map[int]bool{}
		sum := 0.0
		for i, j := range got {
			if seen[j] || !allowed[i][j] {
				t.Fatalf("trial %d: invalid assignment %v", trial, got)
			}
			seen[j] = true
			sum += cost[i][j]
		}
		if want := bruteAssign(cost, allowed); math.Abs(sum-want) > 1e-9 {
			t.Fatalf("trial %d: total %v, least %v", trial, sum, want)
		}
	}
}
