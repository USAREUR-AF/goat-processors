package correlate

import (
	"fmt"
	"math"
	"sort"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
)

// Method confirm (spec/correlate.md 1.0: Association, On each tick, Fused
// output, Snapshot): gate and confirm tests, then either confirm_count with
// hold and hold_failures, or the sequential test (sprt.go); output fused,
// priority or latest.

// confirmMethod is the confirm row of the method table.
type confirmMethod struct{ g *Engine }

func (confirmMethod) reject(*Entity) string { return "" }
func (confirmMethod) restarted(string)      {}
func (m confirmMethod) ingested(e *Entity, events []Obj, trace *[]Obj) []Obj {
	switch {
	case e.Group != "" && m.g.pack.HasSprt:
		return m.g.sprtGroup(e, events, trace)
	case e.Group != "":
		return m.g.hold(e, events, trace)
	}
	return m.g.associate(e, events, trace)
}
func (m confirmMethod) tick(now int64) (events, trace []Obj) { return m.g.tickConfirm(now) }
func (m confirmMethod) snapshot() Obj                        { return m.g.snapshotConfirm() }
func (confirmMethod) moveInto(_, _ string, be, bn model.Axis) (model.Axis, model.Axis) {
	return be, bn
}

func pairKey(a, b string) string {
	if b < a {
		a, b = b, a
	}
	return a + "|" + b
}

// hold runs the hold tests for an entity in a group (spec: Association, hold).
func (g *Engine) hold(a *Entity, events []Obj, trace *[]Obj) []Obj {
	name := a.Group
	passed := false
	for _, bk := range g.groups[name] {
		if bk == a.Key {
			continue
		}
		if g.runTests("hold", g.pack.Hold, a, g.entities[bk], trace) {
			passed = true
			break
		}
	}
	if passed {
		a.HoldFailures = 0
		return events
	}
	a.HoldFailures++
	if a.HoldFailures >= g.pack.HoldFailures {
		events = g.leave(a, "hold", events)
	}
	return events
}

// leave removes an entity from its group and dissolves a group left with one member.
func (g *Engine) leave(a *Entity, reason string, events []Obj) []Obj {
	name := a.Group
	events = append(events, Obj{"ev": "leave", "group": name, "entity": a.Key, "reason": reason})
	a.Group, a.HoldFailures = "", 0
	var rest []string
	for _, k := range g.groups[name] {
		if k != a.Key {
			rest = append(rest, k)
		}
	}
	g.groups[name] = rest
	if len(rest) == 1 {
		last := g.entities[rest[0]]
		events = append(events, Obj{"ev": "dissolve", "group": name, "entity": last.Key})
		last.Group, last.HoldFailures = "", 0
		delete(g.groups, name)
		for i, n := range g.groupOrder {
			if n == name {
				g.groupOrder = append(g.groupOrder[:i], g.groupOrder[i+1:]...)
				break
			}
		}
	}
	return events
}

// groupHasSource reports whether a group holds an entity of the given source.
func (g *Engine) groupHasSource(name, source string) bool {
	for _, k := range g.groups[name] {
		if g.entities[k].Source == source {
			return true
		}
	}
	return false
}

// associate looks for a partner for an ungrouped entity (spec: Association, associate).
func (g *Engine) associate(a *Entity, events []Obj, trace *[]Obj) []Obj {
	p := g.pack
	var ready []*Entity
	for _, bk := range model.SortedKeys(g.entities) {
		b := g.entities[bk]
		if b == a {
			continue
		}
		if p.SameSource != "allow" {
			if b.Source == a.Source || (b.Group != "" && g.groupHasSource(b.Group, a.Source)) {
				continue
			}
		}
		ok := g.runTests("gate", p.Gate, a, b, trace)
		if ok {
			ok = g.runTests("confirm", p.Confirm, a, b, trace)
		}
		if p.HasSprt {
			if g.sprtCandidate(a, b, ok, trace) {
				ready = append(ready, b)
			}
			continue
		}
		pk := pairKey(a.Key, b.Key)
		n := int64(0)
		if ok {
			n = g.counts[pk] + 1
		}
		g.counts[pk] = n
		reached := n >= p.ConfirmCount
		*trace = append(*trace, record("confirm", a, b, "count", n, p.ConfirmCount, reached))
		if reached {
			ready = append(ready, b)
		}
	}
	var chosen *Entity
	best := 0.0
	for _, b := range ready {
		d2 := g.d2(a, b)
		*trace = append(*trace, record("rank", a, b, "rank", d2, nil, true))
		if chosen == nil || d2 < best {
			chosen, best = b, d2
		}
	}
	if chosen == nil {
		return events
	}
	b := chosen
	if b.Group != "" {
		a.Group, a.HoldFailures = b.Group, 0
		members := append(g.groups[b.Group], a.Key)
		sort.Strings(members)
		g.groups[b.Group] = members
		events = append(events, Obj{"ev": "join", "group": b.Group, "entity": a.Key})
	} else {
		name := fmt.Sprintf("g%d", g.nextGroup)
		g.nextGroup++
		members := []string{a.Key, b.Key}
		sort.Strings(members)
		g.groups[name] = members
		g.groupOrder = append(g.groupOrder, name)
		a.Group, b.Group, a.HoldFailures, b.HoldFailures = name, name, 0, 0
		events = append(events, Obj{"ev": "correlate", "group": name, "members": model.Strings(members)})
	}
	if !p.HasSprt {
		g.counts[pairKey(a.Key, b.Key)] = 0
	}
	return events
}

// tickConfirm advances time: staleness, then fused output (spec: Association, On each tick).
func (g *Engine) tickConfirm(now int64) (events, trace []Obj) {
	events, trace = []Obj{}, []Obj{}
	for _, k := range model.SortedKeys(g.entities) {
		e := g.entities[k]
		if !g.isStale(e, now) {
			continue
		}
		if e.Group != "" {
			events = g.leave(e, "stale", events)
		}
		delete(g.entities, k)
		deletePairs(g.counts, k)
		deletePairs(g.llr, k)
		events = append(events, Obj{"ev": "drop", "entity": k})
	}
	for _, name := range g.groupOrder {
		events = append(events, g.fusedEvent(name, now))
	}
	return events, trace
}

// deletePairs removes every pair entry naming entity k.
func deletePairs[V any](pairs map[string]V, k string) {
	for pk := range pairs {
		if pairNames(pk, k) {
			delete(pairs, pk)
		}
	}
}

// fusedEvent is the fused event of one group at now (On each tick, Fused
// output): with output fused the information-weighted combination of every
// member's prediction, otherwise the primary member's prediction.
func (g *Engine) fusedEvent(name string, now int64) Obj {
	members := g.groups[name]
	if g.pack.Output != "fused" {
		var primary *Entity
		for _, k := range members {
			e := g.entities[k]
			if primary == nil || g.better(e, primary) {
				primary = e
			}
		}
		pe, pn := g.predicted(primary, now)
		ev := g.fusedObj(name, primary.Key, members, pe, pn)
		if h, ok := primary.num("hae"); ok {
			ev["hae"] = h
		}
		return ev
	}
	// p = (sum of p_i/pp_i) / (sum of 1/pp_i), v likewise with vv; members
	// in key order, sums left to right from 0, no timing variance.
	var spE, wpE, spN, wpN, svE, wvE, svN, wvN float64
	var haeFrom *Entity
	for _, k := range members {
		e := g.entities[k]
		pe, pn := g.predicted(e, now)
		spE, wpE = spE+pe.P/pe.PP, wpE+1/pe.PP
		spN, wpN = spN+pn.P/pn.PP, wpN+1/pn.PP
		svE, wvE = svE+pe.V/pe.VV, wvE+1/pe.VV
		svN, wvN = svN+pn.V/pn.VV, wvN+1/pn.VV
		if _, ok := e.num("hae"); ok && (haeFrom == nil || e.LastTime > haeFrom.LastTime) {
			haeFrom = e
		}
	}
	ev := g.fusedObj(name, nil, members,
		model.Axis{P: spE / wpE, V: svE / wvE}, model.Axis{P: spN / wpN, V: svN / wvN})
	if haeFrom != nil {
		ev["hae"], _ = haeFrom.num("hae")
	}
	return ev
}

// fusedObj is a fused event without hae, from a position and velocity in the plane.
func (g *Engine) fusedObj(name string, primary any, members []string, pe, pn model.Axis) Obj {
	lat, lon := g.ref.ToDegrees(pe.P, pn.P)
	return Obj{"ev": "fused", "group": name, "primary": primary, "members": model.Strings(members),
		"lat": lat, "lon": lon, "course": model.Course(pe.V, pn.V), "speed_ms": math.Hypot(pe.V, pn.V)}
}

// better reports whether e beats the current primary c; members arrive in key order,
// so a tie keeps c (spec: Fused output).
func (g *Engine) better(e, c *Entity) bool {
	if g.pack.Output == "latest" {
		return e.LastTime > c.LastTime
	}
	return g.priority(e) < g.priority(c)
}

func (g *Engine) priority(e *Entity) int64 {
	if n, ok := g.pack.Priority[e.Source]; ok {
		return n
	}
	return 100
}

// snapshotConfirm returns the whole state of method confirm (spec: Snapshot).
func (g *Engine) snapshotConfirm() Obj {
	ents := Obj{}
	for k, e := range g.entities {
		var grp any
		if e.Group != "" {
			grp = e.Group
		}
		ents[k] = e.filterSnapshot(Obj{"last_time_ms": e.LastTime, "group": grp, "hold_failures": e.HoldFailures})
	}
	groups := Obj{}
	for k, m := range g.groups {
		groups[k] = model.Strings(m)
	}
	counts := Obj{}
	for k, n := range g.counts {
		counts[k] = n
	}
	snap := Obj{"ref": snapshot.Ref(g.ref), "entities": ents, "groups": groups, "counts": counts, "next_group": int64(g.nextGroup)}
	if g.pack.HasSprt {
		llr := Obj{}
		for k, l := range g.llr {
			llr[k] = l
		}
		snap["llr"] = llr
	}
	if iv, ok := g.intervalsSnapshot(); ok {
		snap["intervals"] = iv
	}
	return snap
}
