package correlator

import (
	"fmt"
	"math"
	"sort"
)

// Method assign (spec/correlate-assign.md): system tracks, per-source least-cost
// assignment at each tick, inverse-variance fused estimate.

// fused returns the fused estimate of a set of entities at time t, per axis
// (spec: Assignment, Fused estimate). Only P, V, PP and VV are meaningful.
func (g *Engine) fused(members []string, t int64) (Axis, Axis) {
	var se, sn [4]float64 // sum 1/pp, sum p/pp, sum 1/vv, sum v/vv
	for _, k := range members {
		e, n := g.entities[k].predicted(t, g.pack.AccelVar)
		for _, x := range []struct {
			a Axis
			s *[4]float64
		}{{e, &se}, {n, &sn}} {
			x.s[0] += 1 / x.a.PP
			x.s[1] += x.a.P / x.a.PP
			x.s[2] += 1 / x.a.VV
			x.s[3] += x.a.V / x.a.VV
		}
	}
	mk := func(s [4]float64) Axis {
		pp, vv := 1/s[0], 1/s[2]
		return Axis{P: pp * s[1], V: vv * s[3], PP: pp, VV: vv}
	}
	return mk(se), mk(sn)
}

// cost is d² of entity A against the fused estimate of M at A's time (spec: Cost).
func (g *Engine) cost(a *Entity, members []string) float64 {
	fe, fn := g.fused(members, a.LastTime)
	de, dn := a.East.P-fe.P, a.North.P-fn.P
	return de*de/(a.East.PP+fe.PP) + dn*dn/(a.North.PP+fn.PP)
}

func assignRecord(a, b, test string, value any, pass bool) Obj {
	return Obj{"stage": "assign", "a": a, "b": b, "test": test, "value": value, "limit": nil, "pass": pass}
}

// tickAssign runs one tick: staleness, per-source assignment, output (spec: Assignment).
func (g *Engine) tickAssign(now int64) (events, trace []Obj) {
	events, trace = []Obj{}, []Obj{}
	p := g.pack

	// Staleness.
	for _, k := range sortedKeys(g.entities) {
		e := g.entities[k]
		stale := now-e.LastTime > p.StaleMs
		if s, ok := toInt(e.Last["stale_ms"]); ok && now >= s {
			stale = true
		}
		if !stale {
			continue
		}
		if e.System != "" {
			events = g.leaveSystem(e, "stale", events)
		}
		delete(g.entities, k)
		delete(g.reported, k)
		events = append(events, Obj{"ev": "drop", "entity": k})
	}

	// Entities reported since the previous tick, grouped by source.
	bySource := map[string][]string{}
	for _, k := range sortedKeys(g.reported) {
		bySource[g.entities[k].Source] = append(bySource[g.entities[k].Source], k)
	}
	g.reported = map[string]bool{}
	for _, src := range sortedKeys(bySource) {
		events = g.assignSource(src, bySource[src], events, &trace)
	}

	// Output.
	for _, name := range g.systemOrder {
		members := g.systems[name]
		fe, fn := g.fused(members, now)
		lat, lon := g.toDegrees(fe.P, fn.P)
		course := deg(math.Atan2(fe.V, fn.V))
		if course < 0 {
			course += 360
		}
		if course >= 360 {
			course -= 360
		}
		ev := Obj{"ev": "system", "system": name, "members": strList(members),
			"lat": lat, "lon": lon, "course": course, "speed_ms": math.Hypot(fe.V, fn.V)}
		var src *Entity
		for _, k := range members { // key order: a tie keeps the earlier
			e := g.entities[k]
			if _, ok := e.num("hae"); ok && (src == nil || e.LastTime > src.LastTime) {
				src = e
			}
		}
		if src != nil {
			ev["hae"], _ = src.num("hae")
		}
		events = append(events, ev)
	}
	return events, trace
}

// assignSource assigns one source's reported entities R (key order) (spec: On each tick, 1-4).
func (g *Engine) assignSource(src string, rows []string, events []Obj, trace *[]Obj) []Obj {
	p := g.pack
	inR := map[string]bool{}
	for _, k := range rows {
		inR[k] = true
	}

	// 1. Columns and their others.
	type column struct {
		name   string
		others []string
	}
	var cols []column
	for _, name := range g.systemOrder {
		var others []string
		ok := true
		for _, k := range g.systems[name] {
			if inR[k] {
				continue
			}
			if g.entities[k].Source == src {
				ok = false
			}
			others = append(others, k)
		}
		if ok && len(others) > 0 {
			cols = append(cols, column{name, others})
		}
	}

	// 2. Entries: matrix n x (m + n); column m+i is row i's alone, other alone columns forbidden.
	n, m := len(rows), len(cols)
	cost := make([][]float64, n)
	allowed := make([][]bool, n)
	for i, ak := range rows {
		a := g.entities[ak]
		cost[i] = make([]float64, m+n)
		allowed[i] = make([]bool, m+n)
		for j, c := range cols {
			pass := true
			for _, bk := range c.others {
				if !g.runTests("gate", p.Gate, a, g.entities[bk], trace) {
					pass = false
					break
				}
			}
			if pass {
				cost[i][j] = g.cost(a, c.others)
				if a.System == c.name {
					cost[i][j] -= p.KeepBonus
				}
				allowed[i][j] = true
			}
		}
		alone := p.NewCost
		if a.System != "" && len(g.systems[a.System]) == 1 {
			alone -= p.KeepBonus
		}
		cost[i][m+i], allowed[i][m+i] = alone, true
	}
	for i, ak := range rows {
		for j, c := range cols {
			if allowed[i][j] {
				*trace = append(*trace, assignRecord(ak, c.name, "cost", cost[i][j], true))
			} else {
				*trace = append(*trace, assignRecord(ak, c.name, "cost", nil, false))
			}
		}
		*trace = append(*trace, assignRecord(ak, "alone", "cost", cost[i][m+i], true))
	}

	// 3. Assignment.
	choice := hungarian(cost, allowed)
	for i, ak := range rows {
		b := "alone"
		if choice[i] < m {
			b = cols[choice[i]].name
		}
		*trace = append(*trace, assignRecord(ak, b, "choice", cost[i][choice[i]], true))
	}

	// 4. Apply.
	for i, ak := range rows {
		a := g.entities[ak]
		if choice[i] < m {
			name := cols[choice[i]].name
			if a.System == name {
				continue
			}
			if a.System != "" {
				events = g.leaveSystem(a, "assign", events)
			}
			members := append(g.systems[name], ak)
			sort.Strings(members)
			g.systems[name] = members
			a.System = name
			events = append(events, Obj{"ev": "join", "system": name, "entity": ak})
			continue
		}
		if a.System != "" && len(g.systems[a.System]) == 1 {
			continue
		}
		if a.System != "" {
			events = g.leaveSystem(a, "assign", events)
		}
		name := fmt.Sprintf("s%d", g.nextSystem)
		g.nextSystem++
		g.systems[name] = []string{ak}
		g.systemOrder = append(g.systemOrder, name)
		a.System = name
		events = append(events, Obj{"ev": "start", "system": name, "entity": ak})
	}
	return events
}

// leaveSystem removes an entity from its system track and ends a track left empty.
func (g *Engine) leaveSystem(a *Entity, reason string, events []Obj) []Obj {
	name := a.System
	events = append(events, Obj{"ev": "leave", "system": name, "entity": a.Key, "reason": reason})
	a.System = ""
	var rest []string
	for _, k := range g.systems[name] {
		if k != a.Key {
			rest = append(rest, k)
		}
	}
	if len(rest) > 0 {
		g.systems[name] = rest
		return events
	}
	delete(g.systems, name)
	for i, s := range g.systemOrder {
		if s == name {
			g.systemOrder = append(g.systemOrder[:i], g.systemOrder[i+1:]...)
			break
		}
	}
	return append(events, Obj{"ev": "end", "system": name})
}

// hungarian returns, for each row, the column of an exact minimum-cost assignment
// of n rows to distinct columns among cols >= n, skipping entries not allowed.
// Shortest augmenting paths with potentials; the caller guarantees a feasible
// assignment exists (every row has its own alone column).
func hungarian(cost [][]float64, allowed [][]bool) []int {
	n := len(cost)
	if n == 0 {
		return nil
	}
	m := len(cost[0])
	inf := math.Inf(1)
	// 1-based: u rows, v columns, way[j] previous column, match[j] row of column j.
	u := make([]float64, n+1)
	v := make([]float64, m+1)
	match := make([]int, m+1)
	way := make([]int, m+1)
	for i := 1; i <= n; i++ {
		match[0] = i
		j0 := 0
		minv := make([]float64, m+1)
		used := make([]bool, m+1)
		for j := range minv {
			minv[j] = inf
		}
		for match[j0] != 0 {
			used[j0] = true
			i0, delta, j1 := match[j0], inf, -1
			for j := 1; j <= m; j++ {
				if used[j] {
					continue
				}
				if allowed[i0-1][j-1] {
					if cur := cost[i0-1][j-1] - u[i0] - v[j]; cur < minv[j] {
						minv[j], way[j] = cur, j0
					}
				}
				if minv[j] < delta {
					delta, j1 = minv[j], j
				}
			}
			if j1 < 0 {
				panic("assignment: no feasible column")
			}
			for j := 0; j <= m; j++ {
				if used[j] {
					u[match[j]] += delta
					v[j] -= delta
				} else if minv[j] < inf {
					minv[j] -= delta
				}
			}
			j0 = j1
		}
		for j0 != 0 {
			j1 := way[j0]
			match[j0] = match[j1]
			j0 = j1
		}
	}
	out := make([]int, n)
	for j := 1; j <= m; j++ {
		if match[j] != 0 {
			out[match[j]-1] = j - 1
		}
	}
	return out
}

// snapshotAssign returns the whole state for method assign (spec: correlate-assign.md Snapshot).
func (g *Engine) snapshotAssign() Obj {
	var ref any
	if g.ref != nil {
		ref = []any{g.ref[0], g.ref[1]}
	}
	ents := Obj{}
	for k, e := range g.entities {
		var sys any
		if e.System != "" {
			sys = e.System
		}
		ents[k] = Obj{"last_time_ms": e.LastTime, "system": sys,
			"filter": Obj{"east": e.East.list(), "north": e.North.list()}}
	}
	systems := Obj{}
	for k, m := range g.systems {
		systems[k] = strList(m)
	}
	reported := []any{}
	for _, k := range sortedKeys(g.reported) {
		reported = append(reported, k)
	}
	return Obj{"ref": ref, "entities": ents, "systems": systems, "next_system": int64(g.nextSystem), "reported": reported}
}
