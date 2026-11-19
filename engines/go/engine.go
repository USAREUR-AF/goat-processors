package correlator

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"
)

// Obj is one event, trace record or snapshot map.
type Obj = map[string]any

const earthR = 6371008.8

func rad(x float64) float64 { return x * math.Pi / 180 }
func deg(x float64) float64 { return x * 180 / math.Pi }

// wrap180 brings an angle into (-180, 180] (spec: Frame).
func wrap180(x float64) float64 {
	for x > 180 {
		x -= 360
	}
	for x <= -180 {
		x += 360
	}
	return x
}

// Axis is one axis of the constant-velocity filter (spec: Track estimate).
type Axis struct{ P, V, PP, PV, VV float64 }

// predict is step 1.
func (a Axis) predict(dt, q float64) Axis {
	return Axis{
		P:  a.P + a.V*dt,
		V:  a.V,
		PP: a.PP + 2*dt*a.PV + dt*dt*a.VV + q*dt*dt*dt*dt/4,
		PV: a.PV + dt*a.VV + q*dt*dt*dt/2,
		VV: a.VV + q*dt*dt,
	}
}

// updatePos is step 2.
func (a Axis) updatePos(z, r float64) Axis {
	s := a.PP + r
	k1, k2 := a.PP/s, a.PV/s
	y := z - a.P
	return Axis{
		P:  a.P + k1*y,
		V:  a.V + k2*y,
		PP: (1 - k1) * a.PP,
		PV: (1 - k1) * a.PV,
		VV: a.VV - k2*a.PV,
	}
}

// updateVel is step 3.
func (a Axis) updateVel(z, r float64) Axis {
	s := a.VV + r
	k1, k2 := a.PV/s, a.VV/s
	y := z - a.V
	return Axis{
		P:  a.P + k1*y,
		V:  a.V + k2*y,
		PP: a.PP - k1*a.PV,
		PV: (1 - k2) * a.PV,
		VV: (1 - k2) * a.VV,
	}
}

func (a Axis) list() []any { return []any{a.P, a.V, a.PP, a.PV, a.VV} }

// Entity is one source's track (spec: Track estimate, Snapshot).
type Entity struct {
	Key          string
	Source       string
	LastTime     int64
	East, North  Axis
	Ce           float64
	Last         map[string]any // the last accepted report
	Group        string
	HoldFailures int64
}

// predicted returns copies of both axes predicted to t (spec: Prediction).
func (e *Entity) predicted(t int64, q float64) (Axis, Axis) {
	dt := float64(t-e.LastTime) / 1000
	return e.East.predict(dt, q), e.North.predict(dt, q)
}

func (e *Entity) num(key string) (float64, bool) { return toFloat(e.Last[key]) }

// Engine is one correlator (spec: What the correlator does).
type Engine struct {
	pack       *Pack
	ref        *[2]float64
	entities   map[string]*Entity
	groups     map[string][]string
	groupOrder []string
	counts     map[string]int64
	nextGroup  int
}

// New returns an engine for a loaded pack.
func New(p *Pack) *Engine {
	return &Engine{pack: p, entities: map[string]*Entity{}, groups: map[string][]string{}, counts: map[string]int64{}, nextGroup: 1}
}

func toFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case json.Number:
		f, err := x.Float64()
		return f, err == nil
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	}
	return 0, false
}

func toInt(v any) (int64, bool) {
	switch x := v.(type) {
	case json.Number:
		if i, err := x.Int64(); err == nil {
			return i, true
		}
		f, err := x.Float64()
		return int64(f), err == nil
	case float64:
		return int64(x), true
	case int:
		return int64(x), true
	case int64:
		return x, true
	}
	return 0, false
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

func pairKey(a, b string) string {
	if b < a {
		a, b = b, a
	}
	return a + "|" + b
}

// toPlane converts degrees to metres east and north of the reference (spec: Frame).
func (g *Engine) toPlane(lat, lon float64) (float64, float64) {
	lat0, lon0 := g.ref[0], g.ref[1]
	dlon := wrap180(lon - lon0)
	return earthR * rad(dlon) * math.Cos(rad(lat0)), earthR * rad(lat-lat0)
}

// toDegrees converts plane metres back to degrees (spec: Frame).
func (g *Engine) toDegrees(east, north float64) (float64, float64) {
	lat0, lon0 := g.ref[0], g.ref[1]
	lat := lat0 + deg(north/earthR)
	lon := lon0 + deg(east/(earthR*math.Cos(rad(lat0))))
	return lat, wrap180(lon)
}

// Ingest takes one report (spec: Reports, Track estimate, Association).
func (g *Engine) Ingest(report map[string]any) (events, trace []Obj) {
	for _, k := range []string{"track.source_id", "uid", "time_ms", "lat", "lon"} {
		if !validKey(k, report[k]) {
			return []Obj{{"ev": "reject", "reason": "missing:" + k}}, []Obj{}
		}
	}
	report = cleanOptional(report)
	source := report["track.source_id"].(string)
	key := source + "/" + report["uid"].(string)
	t, _ := toInt(report["time_ms"])
	lat, _ := toFloat(report["lat"])
	lon, _ := toFloat(report["lon"])
	e := g.entities[key]
	if e != nil && t < e.LastTime {
		return []Obj{{"ev": "reject", "entity": key, "reason": "out-of-order"}}, []Obj{}
	}
	events, trace = []Obj{}, []Obj{}
	if g.ref == nil {
		g.ref = &[2]float64{lat, lon}
	}
	p := g.pack
	east, north := g.toPlane(lat, lon)
	ce, ok := toFloat(report["ce"])
	if !ok {
		ce = p.DefaultCeM
	}
	course, hasC := toFloat(report["course"])
	speed, hasS := toFloat(report["speed_ms"])
	hasVel := hasC && hasS
	var ve, vn float64
	if hasVel {
		ve, vn = speed*math.Sin(rad(course)), speed*math.Cos(rad(course))
	}
	if e == nil {
		// First report.
		vv := p.UnknownVelMs * p.UnknownVelMs
		if hasVel {
			vv = p.VelSigmaMs * p.VelSigmaMs
		}
		e = &Entity{Key: key, Source: source,
			East:  Axis{P: east, V: ve, PP: ce * ce, VV: vv},
			North: Axis{P: north, V: vn, PP: ce * ce, VV: vv}}
		g.entities[key] = e
		events = append(events, Obj{"ev": "new", "entity": key})
	} else {
		// Later reports: predict, position update, velocity update.
		e.East, e.North = e.predicted(t, p.AccelVar)
		e.East, e.North = e.East.updatePos(east, ce*ce), e.North.updatePos(north, ce*ce)
		if hasVel {
			r := p.VelSigmaMs * p.VelSigmaMs
			e.East, e.North = e.East.updateVel(ve, r), e.North.updateVel(vn, r)
		}
	}
	e.LastTime, e.Ce, e.Last = t, ce, report

	if e.Group != "" {
		events = g.hold(e, events, &trace)
	} else {
		events = g.associate(e, events, &trace)
	}
	return events, trace
}

// isInt reports whether v is a JSON integer (spec: Reports).
func isInt(v any) bool {
	switch x := v.(type) {
	case json.Number:
		// Written without fraction or exponent: 1000, not 1000.0 or 1e3.
		_, err := x.Int64()
		return err == nil && !strings.ContainsAny(string(x), ".eE")
	case int, int64:
		return true
	}
	return false
}

func isNum(v any) bool { _, ok := toFloat(v); return ok }

// validKey reports whether a report key holds a value of its type (spec: Reports).
func validKey(k string, v any) bool {
	switch k {
	case "track.source_id", "uid", "type":
		_, ok := v.(string)
		return ok
	case "time_ms", "stale_ms":
		return isInt(v)
	case "lat", "lon", "hae", "ce", "course", "speed_ms":
		return isNum(v)
	}
	return true
}

// cleanOptional returns a copy of the report without keys that are null, optional
// keys of the wrong type, and a ce of 0 or below, all treated as absent (spec: Reports).
func cleanOptional(r map[string]any) map[string]any {
	out := make(map[string]any, len(r))
	for k, v := range r {
		if v == nil {
			continue
		}
		switch k {
		case "hae", "ce", "course", "speed_ms", "type", "stale_ms":
			if !validKey(k, v) {
				continue
			}
		}
		if k == "ce" {
			if c, _ := toFloat(v); c <= 0 {
				continue
			}
		}
		out[k] = v
	}
	return out
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
	for _, bk := range sortedKeys(g.entities) {
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
		events = append(events, Obj{"ev": "correlate", "group": name, "members": strList(members)})
	}
	g.counts[pairKey(a.Key, b.Key)] = 0
	return events
}

func strList(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}

func record(stage string, a, b *Entity, test string, value, limit any, pass bool) Obj {
	return Obj{"stage": stage, "a": a.Key, "b": b.Key, "test": test, "value": value, "limit": limit, "pass": pass}
}

// d2 is the squared statistical distance of A's filter from B's prediction (spec: Tests).
func (g *Engine) d2(a, b *Entity) float64 {
	be, bn := b.predicted(a.LastTime, g.pack.AccelVar)
	r := a.Ce * a.Ce
	de, dn := a.East.P-be.P, a.North.P-bn.P
	return de*de/(be.PP+r) + dn*dn/(bn.PP+r)
}

// runTests runs tests in order, stopping at the first failure, and reports whether all passed.
func (g *Engine) runTests(stage string, tests []Test, a, b *Entity, trace *[]Obj) bool {
	for _, t := range tests {
		rec := g.runTest(stage, t, a, b)
		*trace = append(*trace, rec)
		if !rec["pass"].(bool) {
			return false
		}
	}
	return true
}

func clamp(x, lo, hi float64) float64 { return math.Min(math.Max(x, lo), hi) }

// sameValue returns the value a "same" test compares; "@env" is the third element of type.
func sameValue(e *Entity, key string) any {
	if key == "@env" {
		s, ok := e.Last["type"].(string)
		if !ok {
			return nil
		}
		parts := strings.Split(s, "-")
		if len(parts) < 3 {
			return nil
		}
		return parts[2]
	}
	return e.Last[key]
}

func valuesEqual(x, y any) bool {
	if fx, ok := toFloat(x); ok {
		fy, ok := toFloat(y)
		return ok && fx == fy
	}
	switch xv := x.(type) {
	case nil:
		return y == nil
	case string:
		yv, ok := y.(string)
		return ok && xv == yv
	case bool:
		yv, ok := y.(bool)
		return ok && xv == yv
	}
	xb, _ := json.Marshal(x)
	yb, _ := json.Marshal(y)
	return string(xb) == string(yb)
}

// runTest runs one test between A and B predicted to A's time (spec: Tests table).
func (g *Engine) runTest(stage string, t Test, a, b *Entity) Obj {
	skipped := func() Obj {
		r := record(stage, a, b, t.Name, nil, nil, true)
		r["skipped"] = true
		return r
	}
	be, bn := b.predicted(a.LastTime, g.pack.AccelVar)
	dist := math.Hypot(a.East.P-be.P, a.North.P-bn.P)
	switch t.Name {
	case "distance":
		lim := t.Num["max_m"]
		return record(stage, a, b, t.Name, dist, lim, dist < lim)
	case "window":
		lo, hi := t.Num["err_min_m"], t.Num["err_max_m"]
		ea, eb := clamp(a.Ce, lo, hi), clamp(b.Ce, lo, hi)
		lim := t.Num["multiplier"]*math.Sqrt(ea*ea+eb*eb) + t.Num["window_m"]
		return record(stage, a, b, t.Name, dist, lim, dist < lim)
	case "mahalanobis":
		d2 := g.d2(a, b)
		lim := t.Num["gate"]
		return record(stage, a, b, t.Name, d2, lim, d2 < lim)
	case "course", "speed":
		ca, okCa := a.num("course")
		cb, okCb := b.num("course")
		sa, okSa := a.num("speed_ms")
		sb, okSb := b.num("speed_ms")
		min := t.Num["min_speed_ms"]
		if !okSa || !okSb || sa < min || sb < min || (t.Name == "course" && (!okCa || !okCb)) {
			return skipped()
		}
		if t.Name == "course" {
			d := math.Abs(ca - cb)
			v := math.Min(d, 360-d)
			lim := t.Num["max_deg"]
			return record(stage, a, b, t.Name, v, lim, v <= lim)
		}
		slow, fast := math.Min(sa, sb), math.Max(sa, sb)
		v := 0.0
		if fast != 0 {
			v = math.Abs(1-slow/fast) * 100
		}
		lim := t.Num["max_pct"]
		return record(stage, a, b, t.Name, v, lim, v <= lim)
	case "altitude":
		ha, okA := a.num("hae")
		hb, okB := b.num("hae")
		if !okA || !okB {
			return skipped()
		}
		v := math.Abs(ha - hb)
		lim := t.Num["max_m"]
		return record(stage, a, b, t.Name, v, lim, v <= lim)
	case "same":
		va, vb := sameValue(a, t.Key), sameValue(b, t.Key)
		return record(stage, a, b, t.Name, va, vb, valuesEqual(va, vb))
	}
	panic("unknown test " + t.Name)
}

// Tick advances time: staleness, then fused output (spec: Association, On each tick).
func (g *Engine) Tick(now int64) (events, trace []Obj) {
	events, trace = []Obj{}, []Obj{}
	for _, k := range sortedKeys(g.entities) {
		e := g.entities[k]
		stale := now-e.LastTime > g.pack.StaleMs
		if s, ok := toInt(e.Last["stale_ms"]); ok && now >= s {
			stale = true
		}
		if !stale {
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
		pe, pn := primary.predicted(now, g.pack.AccelVar)
		lat, lon := g.toDegrees(pe.P, pn.P)
		course := deg(math.Atan2(pe.V, pn.V))
		if course < 0 {
			course += 360
		}
		if course >= 360 {
			course -= 360
		}
		ev := Obj{"ev": "fused", "group": name, "primary": primary.Key, "members": strList(members),
			"lat": lat, "lon": lon, "course": course, "speed_ms": math.Hypot(pe.V, pn.V)}
		if h, ok := primary.num("hae"); ok {
			ev["hae"] = h
		}
		events = append(events, ev)
	}
	return events, trace
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

// Snapshot returns the whole state (spec: Snapshot).
func (g *Engine) Snapshot() Obj {
	var ref any
	if g.ref != nil {
		ref = []any{g.ref[0], g.ref[1]}
	}
	ents := Obj{}
	for k, e := range g.entities {
		var grp any
		if e.Group != "" {
			grp = e.Group
		}
		ents[k] = Obj{"last_time_ms": e.LastTime, "group": grp, "hold_failures": e.HoldFailures,
			"filter": Obj{"east": e.East.list(), "north": e.North.list()}}
	}
	groups := Obj{}
	for k, m := range g.groups {
		groups[k] = strList(m)
	}
	counts := Obj{}
	for k, n := range g.counts {
		counts[k] = n
	}
	return Obj{"ref": ref, "entities": ents, "groups": groups, "counts": counts, "next_group": int64(g.nextGroup)}
}
