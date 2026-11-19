// Package fuse is the Go engine of spec/fuse.md (version 0.1): it combines the
// reports of the entities named into one group by `fuse.group` into one fused
// estimate per group at each tick.
//
// The per-entity filter, the frame and the report checks are the correlate
// engine's own (package correlator), as spec/fuse.md "Shared with correlate.md"
// requires. Section names in comments refer to spec/fuse.md unless they say
// otherwise.
package fuse

import (
	"math"
	"sort"

	correlator "goat-correlator/engines/go"
)

// Obj is one event, trace record or snapshot map.
type Obj = map[string]any

// Axis is one axis of the correlate filter: p, v, pp, pv, vv.
type Axis = correlator.Axis

// Entity is one source's track.
type Entity struct {
	Key         string
	Source      string
	LastTime    int64
	East, North Axis
	Group       string         // the fuse.group of the last accepted report; "" for none
	Report      map[string]any // the last normalised report
}

// predicted returns copies of both axes predicted to t (correlate.md: Track
// estimate, prediction; dt may be negative).
func (e *Entity) predicted(t int64, q float64) (Axis, Axis) {
	dt := float64(t-e.LastTime) / 1000
	return e.East.Predict(dt, q), e.North.Predict(dt, q)
}

// Engine is one fuse engine (What fuse does: load_pack, ingest, tick, snapshot).
type Engine struct {
	pack     *Pack
	frame    *correlator.Frame // nil until the first accepted report
	entities map[string]*Entity
}

// New returns an engine for a loaded pack.
func New(p *Pack) *Engine {
	return &Engine{pack: p, entities: map[string]*Entity{}}
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// nameOrNull gives a group name, or nil for "no group".
func nameOrNull(group string) any {
	if group == "" {
		return nil
	}
	return group
}

// requiredKeys are checked in the order of the correlate.md Reports table.
var requiredKeys = []string{"track.source_id", "uid", "time_ms", "lat", "lon"}

// normalise removes every key that correlate.md Reports treats as absent, and a
// `fuse.group` that is not a non-empty string (Reports: the normalised report).
func normalise(report map[string]any) map[string]any {
	out := correlator.CleanReport(report)
	if g, ok := out["fuse.group"].(string); !ok || g == "" {
		delete(out, "fuse.group")
	}
	return out
}

// Ingest takes one report (Reports, Groups). A report gives no trace.
func (g *Engine) Ingest(report map[string]any) (events, trace []Obj) {
	trace = []Obj{}

	// Reports: a missing required key rejects the report.
	for _, k := range requiredKeys {
		if !correlator.ValidReportKey(k, report[k]) {
			return []Obj{{"ev": "reject", "reason": "missing:" + k}}, trace
		}
	}
	source := report["track.source_id"].(string)
	key := source + "/" + report["uid"].(string)
	t, _ := correlator.ToInt(report["time_ms"])

	// Reports: a report earlier than the entity's last is ignored; equal is accepted.
	e := g.entities[key]
	if e != nil && t < e.LastTime {
		return []Obj{{"ev": "stale-report", "entity": key, "time_ms": t, "last_time_ms": e.LastTime}}, trace
	}

	r := normalise(report)
	group, _ := r["fuse.group"].(string)

	// correlate.md Frame: the first accepted report fixes the reference.
	lat, _ := correlator.ToFloat(r["lat"])
	lon, _ := correlator.ToFloat(r["lon"])
	if g.frame == nil {
		g.frame = &correlator.Frame{Lat0: lat, Lon0: lon}
	}
	east, north := g.frame.ToPlane(lat, lon)

	// correlate.md Track estimate: measurement, first report or later report.
	p := g.pack
	ce, ok := correlator.ToFloat(r["ce"])
	if !ok {
		ce = p.DefaultCeM
	}
	course, hasCourse := correlator.ToFloat(r["course"])
	speed, hasSpeed := correlator.ToFloat(r["speed_ms"])
	hasVel := hasCourse && hasSpeed
	var ve, vn float64
	if hasVel {
		ve = speed * math.Sin(correlator.Rad(course))
		vn = speed * math.Cos(correlator.Rad(course))
	}

	if e == nil {
		vv := p.UnknownVelMs * p.UnknownVelMs
		if hasVel {
			vv = p.VelSigmaMs * p.VelSigmaMs
		}
		e = &Entity{Key: key, Source: source,
			East:  Axis{P: east, V: ve, PP: ce * ce, VV: vv},
			North: Axis{P: north, V: vn, PP: ce * ce, VV: vv}}
		g.entities[key] = e
		events = []Obj{{"ev": "new", "entity": key, "group": nameOrNull(group)}}
	} else {
		e.East, e.North = e.predicted(t, p.AccelVar)
		e.East, e.North = e.East.UpdatePos(east, ce*ce), e.North.UpdatePos(north, ce*ce)
		if hasVel {
			rv := p.VelSigmaMs * p.VelSigmaMs
			e.East, e.North = e.East.UpdateVel(ve, rv), e.North.UpdateVel(vn, rv)
		}
		events = []Obj{}
		// Groups: a move is applied when the report is accepted, after the filter update.
		if group != e.Group {
			events = append(events, Obj{"ev": "move", "entity": key, "from": nameOrNull(e.Group), "to": nameOrNull(group)})
		}
	}
	e.LastTime, e.Group, e.Report = t, group, r
	return events, trace
}

// group is one output group: its name ("" for an unnamed group) and its members
// in key order.
type group struct {
	name    string
	members []*Entity
}

// groups lists the groups in output order (Groups: Output order of groups):
// named groups in byte order of their name, then the unnamed groups in key order
// of their one member.
func (g *Engine) groups() []group {
	named := map[string][]*Entity{}
	var unnamed []group
	for _, k := range sortedKeys(g.entities) {
		e := g.entities[k]
		if e.Group == "" {
			unnamed = append(unnamed, group{"", []*Entity{e}})
		} else {
			named[e.Group] = append(named[e.Group], e)
		}
	}
	var out []group
	for _, name := range sortedKeys(named) {
		out = append(out, group{name, named[name]})
	}
	return append(out, unnamed...)
}

// isStale is On each tick, step 1.
func (g *Engine) isStale(e *Entity, now int64) bool {
	if now-e.LastTime > g.pack.StaleMs {
		return true
	}
	s, ok := e.Report["stale_ms"]
	if !ok {
		return false
	}
	t, _ := correlator.ToInt(s)
	return now >= t
}

// Tick advances time to now (On each tick).
func (g *Engine) Tick(now int64) (events, trace []Obj) {
	events, trace = []Obj{}, []Obj{}

	// Step 1: staleness, entities in key order.
	for _, k := range sortedKeys(g.entities) {
		e := g.entities[k]
		if g.isStale(e, now) {
			delete(g.entities, k)
			events = append(events, Obj{"ev": "drop", "entity": k, "group": nameOrNull(e.Group)})
		}
	}

	// Step 2: fused output, groups in output order.
	for _, grp := range g.groups() {
		events = append(events, g.fuse(grp, now, &trace))
	}
	return events, trace
}

// member is one member of a group with its filter predicted to now_ms.
type member struct {
	*Entity
	east, north Axis
}

// variance is the position variance var = ppe + ppn (Kinematics).
func (m member) variance() float64 { return m.east.PP + m.north.PP }

// fuse gives the fused event of one group and appends its trace (On each tick, step 2).
func (g *Engine) fuse(grp group, now int64, trace *[]Obj) Obj {
	// 2.1 Predict every member's filter to now_ms.
	members := make([]member, len(grp.members))
	keys := make([]any, len(grp.members))
	for i, e := range grp.members {
		east, north := e.predicted(now, g.pack.AccelVar)
		members[i] = member{e, east, north}
		keys[i] = e.Key
	}

	// 2.2 Combine them by the pack's kinematics method.
	east, north, from := g.kinematics(grp.name, members, trace)

	// 2.3 Decide every attribute, in pack order.
	attributes := Obj{}
	for _, a := range g.pack.Attributes {
		if winner, value, ok := g.attribute(grp.name, a, members, trace); ok {
			attributes[a.Key] = Obj{"value": value, "from": winner}
		}
	}

	// 2.4 The fused event (Fused event).
	lat, lon := g.frame.ToDegrees(east.P, north.P)
	course := correlator.Deg(math.Atan2(east.V, north.V))
	if course < 0 {
		course += 360
	}
	if course >= 360 {
		course -= 360
	}
	ev := Obj{
		"ev": "fused", "group": nameOrNull(grp.name), "members": keys,
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
		h, ok := correlator.ToFloat(from.Report["hae"])
		if !ok {
			return 0, nil
		}
		return h, from
	}
	var by *member
	var hae float64
	for i := range members {
		m := &members[i]
		h, ok := correlator.ToFloat(m.Report["hae"])
		if ok && (by == nil || m.LastTime > by.LastTime) {
			by, hae = m, h
		}
	}
	return hae, by
}

// rank is the rank for a trace record: the index of the source, or nil when unlisted.
func (g *Engine) rank(e *Entity) any {
	if r := g.pack.Rank(e.Source); r >= 0 {
		return int64(r)
	}
	return nil
}

// rankOrder is the rank for comparison: an unlisted source ranks after every listed one.
func (g *Engine) rankOrder(e *Entity) int {
	if r := g.pack.Rank(e.Source); r >= 0 {
		return r
	}
	return len(g.pack.Sources)
}

// Snapshot returns the whole state (Snapshot).
func (g *Engine) Snapshot() Obj {
	var ref any
	if g.frame != nil {
		ref = []any{g.frame.Lat0, g.frame.Lon0}
	}
	entities := Obj{}
	for k, e := range g.entities {
		entities[k] = Obj{
			"last_time_ms": e.LastTime,
			"group":        nameOrNull(e.Group),
			"filter":       Obj{"east": e.East.List(), "north": e.North.List()},
			"report":       e.Report,
		}
	}
	return Obj{"ref": ref, "entities": entities}
}
