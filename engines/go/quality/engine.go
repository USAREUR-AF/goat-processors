package quality

import (
	"math"
	"sort"

	correlator "goat-correlator/engines/go"
)

// Obj is one event, trace record or snapshot map.
type Obj = map[string]any

// Orders of a report (spec: Order).
const (
	orderFirst      = "first"
	orderAdvance    = "advance"
	orderDuplicate  = "duplicate"
	orderOutOfOrder = "out-of-order"
)

// record is one accepted report in an entity's window (spec: Samples).
// A nil sample was not taken.
type record struct {
	wt, timeMs        int64
	order             string
	interval, latency *int64
	nis, speedErr     *float64
	ce, vel, hae      bool // presence flags
}

// entity is one track (spec: Frame and filter, Snapshot).
type entity struct {
	key, source string
	last        int64      // latest accepted time (of a first or advance report)
	lastPos     [2]float64 // plane position of that report, as reported
	east, north correlator.Axis
	window      []record // arrival order
}

// ruleState is a rule's state for one subject (spec: Rules).
type ruleState struct {
	count  int64
	active bool
}

// Engine is one quality stage (spec: What quality does).
type Engine struct {
	pack     *Pack
	ref      *[2]float64
	lastTick *int64
	entities map[string]*entity
	// states[i] holds pack.Rules[i]'s state per subject (entity key or source).
	states []map[string]*ruleState
}

// New returns an engine for a loaded pack.
func New(p *Pack) *Engine {
	g := &Engine{pack: p, entities: map[string]*entity{}}
	for range p.Rules {
		g.states = append(g.states, map[string]*ruleState{})
	}
	return g
}

// reading is what quality reads from one report (spec: Reports). An optional
// key that is null, of the wrong type, or a ce of 0 or below is absent.
type reading struct {
	source, key         string
	t                   int64
	lat, lon            float64
	ce                  float64 // valid ce, or default_ce_m
	hasCe               bool
	course, speed       float64
	hasCourse, hasSpeed bool
	hasHae              bool
	received            int64
	hasReceived         bool
}

// read checks the required keys in table order and reads the optional ones.
// It returns the missing required key, or "".
func (g *Engine) read(report map[string]any) (reading, string) {
	var r reading
	for _, k := range []string{"track.source_id", "uid", "time_ms", "lat", "lon"} {
		if !correlator.ValidKey(k, report[k]) {
			return r, k
		}
	}
	r.source = report["track.source_id"].(string)
	r.key = r.source + "/" + report["uid"].(string)
	r.t, _ = correlator.ToInt(report["time_ms"])
	r.lat, _ = correlator.ToFloat(report["lat"])
	r.lon, _ = correlator.ToFloat(report["lon"])

	r.ce, r.hasCe = correlator.ToFloat(report["ce"])
	if !r.hasCe || r.ce <= 0 {
		r.ce, r.hasCe = g.pack.DefaultCeM, false
	}
	r.course, r.hasCourse = correlator.ToFloat(report["course"])
	r.speed, r.hasSpeed = correlator.ToFloat(report["speed_ms"])
	_, r.hasHae = correlator.ToFloat(report["hae"])
	if correlator.IsInt(report["received_ms"]) {
		r.received, _ = correlator.ToInt(report["received_ms"])
		r.hasReceived = true
	}
	return r, ""
}

func sampleTrace(key, name string, value any, inputs ...any) Obj {
	return Obj{"stage": "sample", "entity": key, "sample": name, "value": value, "inputs": inputs}
}

// Ingest takes one report (spec: Ingest).
func (g *Engine) Ingest(report map[string]any) (events, trace []Obj) {
	// Check the required keys; a reject ends it.
	r, missing := g.read(report)
	if missing != "" {
		return []Obj{{"ev": "reject", "reason": "missing:" + missing}}, []Obj{}
	}
	events, trace = []Obj{}, []Obj{}
	p := g.pack

	// Set the reference if there is none (spec: Frame and filter).
	if g.ref == nil {
		g.ref = &[2]float64{r.lat, r.lon}
	}
	east, north := correlator.ToPlane(*g.ref, r.lat, r.lon)

	// Find the order (spec: Order).
	e := g.entities[r.key]
	rec := record{timeMs: r.t, ce: r.hasCe, vel: r.hasCourse && r.hasSpeed, hae: r.hasHae}
	switch {
	case e == nil:
		rec.order, rec.wt = orderFirst, r.t
		trace = append(trace, sampleTrace(r.key, "order", orderFirst, r.t, nil))
	default:
		switch {
		case r.t > e.last:
			rec.order, rec.wt = orderAdvance, r.t
		case r.t == e.last:
			rec.order, rec.wt = orderDuplicate, e.last
		default:
			rec.order, rec.wt = orderOutOfOrder, e.last
		}
		trace = append(trace, sampleTrace(r.key, "order", rec.order, r.t, e.last))
	}

	// Take the samples, in table order (spec: Samples).
	var predE, predN correlator.Axis
	if rec.order == orderAdvance {
		interval := r.t - e.last
		rec.interval = &interval
		trace = append(trace, sampleTrace(r.key, "interval", interval, r.t, e.last))
	}
	if r.hasReceived {
		latency := r.received - r.t
		rec.latency = &latency
		trace = append(trace, sampleTrace(r.key, "latency", latency, r.received, r.t))
	}
	if rec.order == orderAdvance {
		dt := float64(r.t-e.last) / 1000
		predE, predN = e.east.Predict(dt, p.AccelVar), e.north.Predict(dt, p.AccelVar)
		rr := r.ce * r.ce
		de, dn := east-predE.P, north-predN.P
		se, sn := predE.PP+rr, predN.PP+rr
		nis := de*de/se + dn*dn/sn
		rec.nis = &nis
		trace = append(trace, sampleTrace(r.key, "nis", nis, de, dn, se, sn))
	}
	if rec.order == orderAdvance && r.hasSpeed {
		dt := float64(r.t-e.last) / 1000
		implied := math.Hypot(east-e.lastPos[0], north-e.lastPos[1]) / dt
		speedErr := math.Abs(implied - r.speed)
		rec.speedErr = &speedErr
		trace = append(trace, sampleTrace(r.key, "speed_err", speedErr, implied, r.speed))
	}

	// Create the entity, or update its filter, last and last_pos
	// (correlate.md, Track estimate).
	var ve, vn float64
	if rec.vel {
		ve, vn = r.speed*math.Sin(rad(r.course)), r.speed*math.Cos(rad(r.course))
	}
	switch rec.order {
	case orderFirst:
		vv := p.UnknownVelMs * p.UnknownVelMs
		if rec.vel {
			vv = p.VelSigmaMs * p.VelSigmaMs
		}
		e = &entity{key: r.key, source: r.source,
			east:  correlator.Axis{P: east, V: ve, PP: r.ce * r.ce, VV: vv},
			north: correlator.Axis{P: north, V: vn, PP: r.ce * r.ce, VV: vv}}
		g.entities[r.key] = e
		events = append(events, Obj{"ev": "new", "entity": r.key})
	case orderAdvance:
		e.east, e.north = predE.UpdatePos(east, r.ce*r.ce), predN.UpdatePos(north, r.ce*r.ce)
		if rec.vel {
			rv := p.VelSigmaMs * p.VelSigmaMs
			e.east, e.north = e.east.UpdateVel(ve, rv), e.north.UpdateVel(vn, rv)
		}
	}
	if rec.order == orderFirst || rec.order == orderAdvance {
		e.last, e.lastPos = r.t, [2]float64{east, north}
	}

	// Append the record; emit pass.
	e.window = append(e.window, rec)
	events = append(events, g.forward(e, report, r))
	return events, trace
}

func rad(x float64) float64 { return x * math.Pi / 180 }

// inForce returns the rules whose actions are in force for the entity's
// reports, other than alert, in pack order (spec: Rules, Actions).
func (g *Engine) inForce(e *entity) []Rule {
	var out []Rule
	for i, rule := range g.pack.Rules {
		subject := e.key
		if rule.Scope == "source" {
			subject = e.source
		}
		if st := g.states[i][subject]; st != nil && st.active && rule.Action != "alert" {
			out = append(out, rule)
		}
	}
	return out
}

// forward builds the pass event (spec: Forwarding).
func (g *Engine) forward(e *entity, report map[string]any, r reading) Obj {
	rules := g.inForce(e)
	names := []any{}
	var withheld, downgrade, mark bool
	for _, rule := range rules {
		names = append(names, rule.Name)
		switch rule.Action {
		case "drop":
			withheld = true
		case "downgrade":
			downgrade = true
		case "mark":
			mark = true
		}
	}
	ev := Obj{"ev": "pass", "entity": e.key, "rules": names, "withheld": withheld}
	if withheld {
		return ev
	}

	// The report exactly as received, with the changes below.
	out := make(map[string]any, len(report))
	for k, v := range report {
		out[k] = v
	}
	if downgrade {
		x := r.ce // the valid ce, or default_ce_m
		for _, rule := range rules {
			if rule.Action == "downgrade" {
				x = x * rule.Factor
			}
		}
		out["ce"] = x
	}
	if mark {
		marks := []any{}
		if list, ok := report["quality.marks"].([]any); ok && allStrings(list) {
			marks = append(marks, list...)
		}
		for _, rule := range rules {
			if rule.Action == "mark" && !containsAny(marks, rule.Name) {
				marks = append(marks, rule.Name)
			}
		}
		out["quality.marks"] = marks
	}
	ev["report"] = out
	return ev
}

func allStrings(list []any) bool {
	for _, x := range list {
		if _, ok := x.(string); !ok {
			return false
		}
	}
	return true
}

func containsAny(list []any, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks) // byte order
	return ks
}
