package correlate

import (
	"sort"

	"goat-correlator/engines/go/model"
)

// Staleness (spec/correlate.md 1.0: On each tick, Staleness; Stale time of
// a source), shared by both methods.

// addInterval appends one interval of a source (an accepted report of an
// entity that already existed) when the pack has stale_rate, keeping the
// last n.
func (g *Engine) addInterval(source string, dt int64) {
	if !g.pack.HasStaleRate {
		return
	}
	list := append(g.intervals[source], dt)
	if n := int(g.pack.StaleRate.Samples); len(list) > n {
		list = append([]int64(nil), list[len(list)-n:]...)
	}
	g.intervals[source] = list
}

// staleTime is a source's stale time in ms: stale_ms, or with stale_rate k
// times the lower median of its intervals, between floor and ceiling, and
// the ceiling with no interval.
func (g *Engine) staleTime(source string) float64 {
	p := g.pack
	if !p.HasStaleRate {
		return float64(p.StaleMs)
	}
	sr := p.StaleRate
	list := g.intervals[source]
	if len(list) == 0 {
		return float64(sr.CeilingMs)
	}
	sorted := append([]int64(nil), list...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	st := sr.Factor * float64(sorted[(len(sorted)-1)/2])
	if f := float64(sr.FloorMs); st < f {
		st = f
	}
	if c := float64(sr.CeilingMs); st > c {
		st = c
	}
	return st
}

// isStale reports whether an entity is stale at now.
func (g *Engine) isStale(e *Entity, now int64) bool {
	if float64(now-e.LastTime) > g.staleTime(e.Source) {
		return true
	}
	s, ok := model.ToInt(e.Last["stale_ms"])
	return ok && now >= s
}

// intervalsSnapshot is the snapshot's intervals: each source with at least
// one interval, oldest first; ok is false without stale_rate.
func (g *Engine) intervalsSnapshot() (Obj, bool) {
	if !g.pack.HasStaleRate {
		return nil, false
	}
	out := Obj{}
	for src, list := range g.intervals {
		l := make([]any, len(list))
		for i, v := range list {
			l[i] = v
		}
		out[src] = l
	}
	return out, true
}
