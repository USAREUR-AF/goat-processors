package filter

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Ingest decides one report (spec: Reports, Rules, Events, Trace).
func (g *Engine) Ingest(in map[string]any) (events, tr []Obj) {
	// Reports: required keys, then optional keys (shared with correlate).
	values, missing := model.ReadReport(in)
	if missing != "" {
		return []Obj{model.Reject(missing)}, []Obj{}
	}
	r := &report{values: values}
	r.source = values["track.source_id"].(string)
	r.uid = values["uid"].(string)
	r.key = r.source + "/" + r.uid
	r.timeMs, _ = model.ToInt(values["time_ms"])
	r.lat, _ = model.ToFloat(values["lat"])
	r.lon, _ = model.ToFloat(values["lon"])

	// Rules 1-2: the first rule whose conditions all pass decides; else default.
	tr = []Obj{}
	action, ruleName := g.pack.Default, "default"
	for _, rule := range g.pack.Rules {
		if g.ruleMatches(rule, r, &tr) {
			action, ruleName = rule.Action, rule.Name
			break
		}
	}

	// Rules 3: one event.
	events = []Obj{{"ev": action, "entity": r.key, "rule": ruleName}}

	// Rules 4: state, after the decision.
	g.updateState(r, action == "keep")
	return events, tr
}

// ruleMatches evaluates a rule's conditions in pack order, one trace record
// each, stopping at the first that does not pass.
func (g *Engine) ruleMatches(rule Rule, r *report, tr *[]Obj) bool {
	for _, c := range rule.Conditions {
		res := c.eval(c, r, g.entities)
		pass := res.passes(c.Negated)
		*tr = append(*tr, trace.Rule(rule.Name, r.key, c.Name, c.Negated, res.value, res.limit, pass, res.truth == unknown))
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
		i, _ := model.ToInt(v)
		s.StaleMs = &i
	}
}
