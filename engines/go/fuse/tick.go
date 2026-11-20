package fuse

import (
	"math"

	"goat-correlator/engines/go/model"
)

// isStale is On each tick, step 1.
func (g *Engine) isStale(e *Entity, now int64) bool {
	if now-e.LastTime > g.pack.StaleMs {
		return true
	}
	s, ok := e.Report["stale_ms"]
	if !ok {
		return false
	}
	t, _ := model.ToInt(s)
	return now >= t
}

// Tick advances time to now (On each tick).
func (g *Engine) Tick(now int64) (events, tr []Obj) {
	events, tr = []Obj{}, []Obj{}

	// Step 1: staleness, entities in key order.
	for _, k := range model.SortedKeys(g.entities) {
		e := g.entities[k]
		if g.isStale(e, now) {
			delete(g.entities, k)
			events = append(events, Obj{"ev": "drop", "entity": k, "group": model.OrNull(e.Group)})
		}
	}

	// Step 2: fused output, groups in output order.
	for _, grp := range g.groups() {
		events = append(events, g.fuse(grp, now, &tr))
	}
	return events, tr
}

// member is one member of a group with its filter predicted to now_ms.
type member struct {
	*Entity
	east, north Axis
}

// variance is the position variance var = ppe + ppn (Kinematics).
func (m member) variance() float64 { return m.east.PP + m.north.PP }

// fuse gives the fused event of one group and appends its trace (On each tick, step 2).
func (g *Engine) fuse(grp group, now int64, tr *[]Obj) Obj {
	// 2.1 Predict every member's filter to now_ms.
	members := make([]member, len(grp.members))
	keys := make([]any, len(grp.members))
	for i, e := range grp.members {
		east, north := e.predicted(now, g.pack.AccelVar)
		members[i] = member{e, east, north}
		keys[i] = e.Key
	}

	// 2.2 Combine them by the pack's kinematics method.
	east, north, from := g.kinematics(grp.name, members, tr)

	// 2.3 Decide every attribute, in pack order.
	attributes := Obj{}
	for _, a := range g.pack.Attributes {
		if winner, value, ok := g.attribute(grp.name, a, members, tr); ok {
			attributes[a.Key] = Obj{"value": value, "from": winner}
		}
	}

	// 2.4 The fused event (Fused event).
	lat, lon := g.frame.ToDegrees(east.P, north.P)
	course := model.Course(east.V, north.V)
	ev := Obj{
		"ev": "fused", "group": model.OrNull(grp.name), "members": keys,
		"from": nil, "lat": lat, "lon": lon, "course": course,
		"speed_ms":   math.Hypot(east.V, north.V),
		"ce":         math.Sqrt((east.PP + north.PP) / 2),
		"attributes": attributes,
	}
	if from != nil {
		ev["from"] = from.Key
	}
	if h, by := g.height(members, from); by != nil {
		ev["hae"], ev["hae_from"] = h, by.Key
	}
	return ev
}

// height is Fused event, Height: the kinematics member's hae for best, priority
// and latest; otherwise the hae of the member with the greatest last_time_ms that
// has one, ties to key order. It returns a nil member when no height is known.
func (g *Engine) height(members []member, from *member) (float64, *member) {
	if from != nil {
		h, ok := model.ToFloat(from.Report["hae"])
		if !ok {
			return 0, nil
		}
		return h, from
	}
	var by *member
	var hae float64
	for i := range members {
		m := &members[i]
		h, ok := model.ToFloat(m.Report["hae"])
		if ok && (by == nil || m.LastTime > by.LastTime) {
			by, hae = m, h
		}
	}
	return hae, by
}
