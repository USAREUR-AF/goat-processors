package correlate

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
	"goat-correlator/engines/go/trace"
)

// The per-entity filter: one constant-velocity model (Track estimate) or,
// with the pack's maneuver line, two (Two-model filter). The math is
// model's; this file keeps the entity's state.

// startFilter sets an entity's filter from its first report.
func (g *Engine) startFilter(e *Entity, z model.Measurement) {
	p := g.pack
	first := p.FilterParams.First(z)
	e.East, e.North = first.East, first.North
	if p.HasManeuver {
		// Both models are the first-report filter; mu is the long-run share.
		e.IMM = &model.IMM{Models: [2]model.Model{first, first}, Mode: p.Maneuver.Start()}
	}
}

// updateFilter applies a later report at time t and returns the filter
// trace records (none with one model).
func (g *Engine) updateFilter(e *Entity, t int64, z model.Measurement) []Obj {
	p := g.pack
	dt := float64(t-e.LastTime) / 1000
	if !p.HasManeuver {
		m := p.FilterParams.Update(model.Model{East: e.East, North: e.North}.Predict(dt, p.AccelVar), z)
		e.East, e.North = m.East, m.North
		return nil
	}
	s := e.IMM.Update(p.FilterParams, p.Maneuver, dt, z)
	*e.IMM = s.IMM // in place: the entity owns its models
	e.East, e.North = s.Combined.East, s.Combined.North
	names := model.ModelNames
	return []Obj{
		trace.Model(e.Key, names[0], "likelihood", s.Lambda[0]), trace.Model(e.Key, names[1], "likelihood", s.Lambda[1]),
		trace.Model(e.Key, names[0], "mode", s.Mode[0]), trace.Model(e.Key, names[1], "mode", s.Mode[1]),
	}
}

// predicted returns copies of both axes of an entity's filter predicted to t
// (Track estimate, Prediction; Two-model filter, Prediction). It never changes e.
func (g *Engine) predicted(e *Entity, t int64) (model.Axis, model.Axis) {
	p := g.pack
	dt := float64(t-e.LastTime) / 1000
	if e.IMM == nil {
		return e.East.Predict(dt, p.AccelVar), e.North.Predict(dt, p.AccelVar)
	}
	m := e.IMM.Predict(p.FilterParams, p.Maneuver, dt)
	return m.East, m.North
}

// withTimingVariance adds an entity's timing variance to the pp of a
// prediction of it that is compared with another entity (Track estimate:
// before any other change to that prediction, such as the bias move).
func withTimingVariance(e *Entity, pe, pn model.Axis) (model.Axis, model.Axis) {
	return model.AddVariance(pe, pn, e.TimeVarEast, e.TimeVarNorth)
}

// predictedFor returns B predicted to A's time, with B's timing variance
// added to its pp and then moved into A's frame by the method: the
// prediction every test between A and B reads (Tests; Sensor bias).
func (g *Engine) predictedFor(b, a *Entity) (model.Axis, model.Axis) {
	be, bn := g.predicted(b, a.LastTime)
	be, bn = withTimingVariance(b, be, bn)
	return g.method.moveInto(b.Source, a.Source, be, bn)
}

// filterSnapshot is the entity's filter fields of the snapshot (Snapshot).
func (e *Entity) filterSnapshot(out Obj) Obj {
	out["filter"] = snapshot.Filter(model.Model{East: e.East, North: e.North})
	if e.HasTime {
		out["time"] = Obj{"var_east": e.TimeVarEast, "var_north": e.TimeVarNorth}
	}
	if e.IMM != nil {
		models := Obj{}
		for j, name := range model.ModelNames {
			models[name] = snapshot.Filter(e.IMM.Models[j])
		}
		out["models"] = models
		out["mode"] = []any{e.IMM.Mode[0], e.IMM.Mode[1]}
	}
	return out
}
