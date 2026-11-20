package correlate

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
)

// Method confirm (spec/correlate.md: Association, On each tick, Fused
// output, Snapshot): gate and confirm tests, confirm_count, hold and
// hold_failures, fixed staleness, output priority|latest. This pipeline is
// left as it was until correlate 1.0 replaces it; it is only moved here
// and called through the method table.

// confirmMethod is the confirm row of the method table.
type confirmMethod struct{ g *Engine }

func (confirmMethod) reject(*Entity) string { return "" }
func (confirmMethod) restarted(string)      {}
func (m confirmMethod) ingested(e *Entity, events []Obj, trace *[]Obj) []Obj {
	if e.Group != "" {
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
	g.counts[pairKey(a.Key, b.Key)] = 0
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
		for pk := range g.counts {
			a, b, _ := strings.Cut(pk, "|")
			if a == k || b == k {
				delete(g.counts, pk)
			}
		}
		events = append(events, Obj{"ev": "drop", "entity": k})
	}
	for _, name := range g.groupOrder {
		members := g.groups[name]
		var primary *Entity
		for _, k := range members {
			e := g.entities[k]
			if primary == nil || g.better(e, primary) {
				primary = e
			}
		}
		pe, pn := g.predicted(primary, now)
		lat, lon := g.ref.ToDegrees(pe.P, pn.P)
		course := model.Course(pe.V, pn.V)
		ev := Obj{"ev": "fused", "group": name, "primary": primary.Key, "members": model.Strings(members),
			"lat": lat, "lon": lon, "course": course, "speed_ms": math.Hypot(pe.V, pn.V)}
		if h, ok := primary.num("hae"); ok {
			ev["hae"] = h
		}
		events = append(events, ev)
	}
	return events, trace
}

// isStale reports whether an entity is stale at now (spec: On each tick, Staleness).
func (g *Engine) isStale(e *Entity, now int64) bool {
	if now-e.LastTime > g.pack.StaleMs {
		return true
	}
	s, ok := model.ToInt(e.Last["stale_ms"])
	return ok && now >= s
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
	return Obj{"ref": snapshot.Ref(g.ref), "entities": ents, "groups": groups, "counts": counts, "next_group": int64(g.nextGroup)}
}
