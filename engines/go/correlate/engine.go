// Package correlate is the Go engine of spec/correlate.md (version 0.8) and,
// through package assign, spec/correlate-assign.md (version 0.6). The
// pack's `method` line selects the method from the table in methods.go.
//
// Files by section of correlate.md: engine.go (What the correlator does),
// reports.go (Reports, Time quality), track.go (Track estimate, Two-model
// filter), restart.go (Restart), tests.go (Tests), confirm.go
// (Association, method confirm), snapshot.go (Snapshot), pack.go and
// methods.go (Pack). assign.go connects package assign.
package correlate

import (
	"goat-correlator/engines/go/model"
)

// Obj is one event, trace record or snapshot map.
type Obj = model.Obj

// Entity is one source's track (spec: Track estimate, Snapshot).
type Entity struct {
	Key          string
	Source       string
	LastTime     int64
	East, North  model.Axis // the filter; with two models, their combination
	IMM          *model.IMM // with the maneuver line: quiet and maneuver, and mu (Two-model filter)
	Ce           float64
	REast        float64        // the last report's measurement variance r_east (Track estimate)
	RNorth       float64        // the last report's measurement variance r_north
	HasTime      bool           // the last report's time error was above 0 (Snapshot: time)
	TimeVarEast  float64        // timing variance (v_e*ts)², 0 when the time error is 0
	TimeVarNorth float64        // timing variance (v_n*ts)², 0 when the time error is 0
	Last         map[string]any // the last accepted report

	// method confirm (Association)
	Group        string
	HoldFailures int64
}

func (e *Entity) num(key string) (float64, bool) { return model.ToFloat(e.Last[key]) }

// Engine is one correlator (spec: What the correlator does).
type Engine struct {
	pack     *Pack
	ref      *model.Frame
	entities map[string]*Entity
	method   method

	// method confirm (Association): left as is until correlate 1.0.
	groups     map[string][]string
	groupOrder []string
	counts     map[string]int64
	nextGroup  int
}

var _ model.Engine = (*Engine)(nil)

// New returns an engine for a loaded pack.
func New(p *Pack) *Engine {
	g := &Engine{pack: p, entities: map[string]*Entity{}, groups: map[string][]string{}, counts: map[string]int64{}, nextGroup: 1}
	g.method = methods[p.Method].new(g)
	return g
}

// Load loads the pack in dir and returns a new engine for it.
func Load(dir string) (*Engine, error) {
	p, err := LoadPack(dir)
	if err != nil {
		return nil, err
	}
	return New(p), nil
}

// Ingest takes one report (spec: Reports, Track estimate, then the method).
func (g *Engine) Ingest(report map[string]any) (events, trace []Obj) {
	if k := model.MissingKey(report); k != "" {
		return []Obj{model.Reject(k)}, []Obj{}
	}
	report = model.CleanTimeQuality(model.CleanOptional(report))
	source, key := model.EntityKey(report)
	t, _ := model.ToInt(report["time_ms"])
	e := g.entities[key]
	if e != nil {
		if reason := g.method.reject(e); reason != "" {
			return []Obj{{"ev": "reject", "entity": key, "reason": reason}}, []Obj{}
		}
		if t < e.LastTime {
			return []Obj{{"ev": "reject", "entity": key, "reason": "out-of-order"}}, []Obj{}
		}
	}
	events, trace = []Obj{}, []Obj{}
	lat, _ := model.ToFloat(report["lat"])
	lon, _ := model.ToFloat(report["lon"])
	if g.ref == nil {
		g.ref = &model.Frame{Lat0: lat, Lon0: lon}
	}
	z, ce, te, varE, varN := g.measure(e, source, key, t, report, lat, lon, &trace)

	if e == nil {
		e = &Entity{Key: key, Source: source}
		g.startFilter(e, z)
		g.entities[key] = e
		events = append(events, Obj{"ev": "new", "entity": key})
	} else if g.restartTest(e, t, z, &trace) {
		trace = append(trace, g.updateFilter(e, t, z)...)
	} else {
		// Restart: the filter starts again from this report as a first
		// report; the entity keeps its key, group, pair counts and hold
		// failure count, and no new event is given.
		g.startFilter(e, z)
		g.method.restarted(key)
	}
	e.LastTime, e.Ce, e.Last = t, ce, report
	e.REast, e.RNorth = z.REast, z.RNorth
	e.HasTime, e.TimeVarEast, e.TimeVarNorth = te > 0, varE, varN
	return g.method.ingested(e, events, &trace), trace
}

// Tick advances time (the method's On each tick).
func (g *Engine) Tick(now int64) (events, trace []Obj) { return g.method.tick(now) }

// Snapshot returns the whole state (spec: Snapshot).
func (g *Engine) Snapshot() Obj { return g.method.snapshot() }
