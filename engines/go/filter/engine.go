package filter

import (
	"sort"
	"strings"

	correlator "goat-correlator/engines/go"
)

// Obj is one event, trace record or snapshot map.
type Obj = map[string]any

// State is the stored state of one entity (spec: Snapshot, Rules step 4).
type State struct {
	TimeMs   int64
	Lat, Lon float64
	Course   *float64 // nil = null
	SpeedMs  *float64
	StaleMs  *int64
	KeptMs   *int64 // nil until a report of the entity is kept
}

// Engine runs one pack.
type Engine struct {
	pack     *Pack
	entities map[string]*State
}

// New returns an engine for a loaded pack, with no state.
func New(p *Pack) *Engine {
	return &Engine{pack: p, entities: map[string]*State{}}
}

// report is one accepted report, read by the rules of Reports.
type report struct {
	key      string         // entity key <track.source_id>/<uid>
	values   map[string]any // the report with absent keys removed
	source   string
	uid      string
	timeMs   int64
	lat, lon float64
}

func (r *report) num(k string) *float64 {
	if v, ok := r.values[k]; ok {
		f, _ := correlator.ToFloat(v)
		return &f
	}
	return nil
}

func (r *report) str(k string) (string, bool) {
	s, ok := r.values[k].(string)
	return s, ok
}

// environment is the third `-`-separated element of type (spec: Reports).
func (r *report) environment() (string, bool) {
	t, ok := r.str("type")
	if !ok {
		return "", false
	}
	parts := strings.Split(t, "-")
	if len(parts) < 3 {
		return "", false
	}
	return parts[2], true
}

// affiliation is the second element of type when the first is exactly `a`.
func (r *report) affiliation() (string, bool) {
	t, ok := r.str("type")
	if !ok {
		return "", false
	}
	parts := strings.Split(t, "-")
	if len(parts) < 2 || parts[0] != "a" {
		return "", false
	}
	return parts[1], true
}

// Ingest decides one report (spec: Reports, Rules, Events, Trace).
func (g *Engine) Ingest(in map[string]any) (events, trace []Obj) {
	// Reports: required keys, then optional keys (shared with correlate).
	values, missing := correlator.ReadReport(in)
	if missing != "" {
		return []Obj{{"ev": "reject", "reason": "missing:" + missing}}, []Obj{}
	}
	r := &report{values: values}
	r.source = values["track.source_id"].(string)
	r.uid = values["uid"].(string)
	r.key = r.source + "/" + r.uid
	r.timeMs, _ = correlator.ToInt(values["time_ms"])
	r.lat, _ = correlator.ToFloat(values["lat"])
	r.lon, _ = correlator.ToFloat(values["lon"])

	// Rules 1-2: the first rule whose conditions all pass decides; else default.
	trace = []Obj{}
	action, ruleName := g.pack.Default, "default"
	for _, rule := range g.pack.Rules {
		if g.ruleMatches(rule, r, &trace) {
			action, ruleName = rule.Action, rule.Name
			break
		}
	}

	// Rules 3: one event.
	events = []Obj{{"ev": action, "entity": r.key, "rule": ruleName}}

	// Rules 4: state, after the decision.
	g.updateState(r, action == "keep")
	return events, trace
}

// ruleMatches evaluates a rule's conditions in pack order, one trace record
// each, stopping at the first that does not pass.
func (g *Engine) ruleMatches(rule Rule, r *report, trace *[]Obj) bool {
	for _, c := range rule.Conditions {
		res := g.evaluate(c, r)
		pass := res.passes(c.Negated)
		rec := Obj{"stage": "rule", "rule": rule.Name, "entity": r.key, "test": c.Name,
			"negated": c.Negated, "value": res.value, "limit": res.limit, "pass": pass}
		if res.truth == unknown {
			rec["unknown"] = true
		}
		*trace = append(*trace, rec)
		if !pass {
			return false
		}
	}
	return true
}

// updateState applies Rules step 4.
func (g *Engine) updateState(r *report, kept bool) {
	s := g.entities[r.key]
	if s == nil {
		// An entity with no state gets state from this report, kept_ms null.
		s = &State{}
		g.entities[r.key] = s
		g.replacePosition(s, r)
	} else if r.timeMs >= s.TimeMs {
		// A report at or after the stored time replaces it; an older one does not.
		g.replacePosition(s, r)
	}
	if kept && (s.KeptMs == nil || *s.KeptMs < r.timeMs) {
		t := r.timeMs
		s.KeptMs = &t
	}
}

// replacePosition stores time_ms, lat, lon, course, speed_ms and stale_ms
// from the report; absent keys are stored as null.
func (g *Engine) replacePosition(s *State, r *report) {
	s.TimeMs, s.Lat, s.Lon = r.timeMs, r.lat, r.lon
	s.Course, s.SpeedMs = r.num("course"), r.num("speed_ms")
	s.StaleMs = nil
	if v, ok := r.values["stale_ms"]; ok {
		i, _ := correlator.ToInt(v)
		s.StaleMs = &i
	}
}

// Tick forgets entities that have not reported for longer than forget_ms
// (spec: Tick).
func (g *Engine) Tick(now int64) (events, trace []Obj) {
	events, trace = []Obj{}, []Obj{}
	for _, key := range g.keys() {
		age := now - g.entities[key].TimeMs
		forget := age > g.pack.ForgetMs
		trace = append(trace, Obj{"stage": "forget", "entity": key, "test": "age",
			"value": age, "limit": g.pack.ForgetMs, "pass": forget})
		if forget {
			delete(g.entities, key)
			events = append(events, Obj{"ev": "forget", "entity": key})
		}
	}
	return events, trace
}

// keys returns the entity keys in ascending byte order.
func (g *Engine) keys() []string {
	ks := make([]string, 0, len(g.entities))
	for k := range g.entities {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// Snapshot returns the whole state (spec: Snapshot).
func (g *Engine) Snapshot() Obj {
	ents := Obj{}
	for key, s := range g.entities {
		ents[key] = Obj{"time_ms": s.TimeMs, "lat": s.Lat, "lon": s.Lon,
			"course": floatOrNull(s.Course), "speed_ms": floatOrNull(s.SpeedMs),
			"stale_ms": intOrNull(s.StaleMs), "kept_ms": intOrNull(s.KeptMs)}
	}
	return Obj{"entities": ents}
}

func floatOrNull(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

func intOrNull(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}
