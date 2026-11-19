package correlator

import "math"

// The per-entity filter: one constant-velocity model (correlate.md: Track
// estimate) or, with the pack's maneuver line, two models combined as an
// interacting multiple model filter (correlate.md: Two-model filter).

// Model is one constant-velocity filter, both axes.
type Model struct{ East, North Axis }

// modelNames are the models of the two-model filter, by index (quiet = 1, maneuver = 2).
var modelNames = [2]string{"quiet", "maneuver"}

// Measurement is what one report gives the filter, in the plane.
type Measurement struct {
	East, North float64 // position, m
	REast       float64 // r_east, the position variance east (Track estimate, Measurement variance)
	RNorth      float64 // r_north, the position variance north
	HasVel      bool
	VE, VN      float64 // velocity, m/s, when HasVel
}

// firstModel is the first-report filter (Track estimate, First report).
func (p *Pack) firstModel(z Measurement) Model {
	vv := p.UnknownVelMs * p.UnknownVelMs
	if z.HasVel {
		vv = p.VelSigmaMs * p.VelSigmaMs
	}
	return Model{
		East:  Axis{P: z.East, V: z.VE, PP: z.REast, VV: vv},
		North: Axis{P: z.North, V: z.VN, PP: z.RNorth, VV: vv},
	}
}

// step runs Track estimate steps 1 to 3 on a model with acceleration variance q
// and returns the updated model and g, the sum of y*y/s + ln(s) over the scalar
// updates in the order east position, north position, east velocity, north
// velocity (Two-model filter, step 3).
func (p *Pack) step(m Model, dt, q float64, z Measurement) (Model, float64) {
	g := 0.0
	term := func(y, s float64) { g = g + (y*y/s + math.Log(s)) }

	e, n := m.East.predict(dt, q), m.North.predict(dt, q)
	var y, s float64
	e, y, s = e.updatePos(z.East, z.REast)
	term(y, s)
	n, y, s = n.updatePos(z.North, z.RNorth)
	term(y, s)
	if z.HasVel {
		r := p.VelSigmaMs * p.VelSigmaMs
		e, y, s = e.updateVel(z.VE, r)
		term(y, s)
		n, y, s = n.updateVel(z.VN, r)
		term(y, s)
	}
	return Model{e, n}, g
}

// blend combines two states with weights w1, w2 (Two-model filter, step 1).
func blend(w1, w2 float64, a1, a2 Axis) Axis {
	p := w1*a1.P + w2*a2.P
	v := w1*a1.V + w2*a2.V
	d1, e1, d2, e2 := a1.P-p, a1.V-v, a2.P-p, a2.V-v
	return Axis{
		P:  p,
		V:  v,
		PP: w1*(a1.PP+d1*d1) + w2*(a2.PP+d2*d2),
		PV: w1*(a1.PV+d1*e1) + w2*(a2.PV+d2*e2),
		VV: w1*(a1.VV+e1*e1) + w2*(a2.VV+e2*e2),
	}
}

func blendModels(w1, w2 float64, m [2]Model) Model {
	return Model{blend(w1, w2, m[0].East, m[1].East), blend(w1, w2, m[0].North, m[1].North)}
}

// switching returns t[i][j], the probability of model j at the end of dt seconds
// given model i at its start (Two-model filter, Switching).
func (p *Pack) switching(dt float64) [2][2]float64 {
	a, b := p.PEnter, p.PLeave
	s := a + b
	l := math.Pow(1-s, dt)
	t12 := a / s * (1 - l)
	t21 := b / s * (1 - l)
	return [2][2]float64{{1 - t12, t12}, {t21, 1 - t21}}
}

// startFilter sets an entity's filter from its first report.
func (g *Engine) startFilter(e *Entity, z Measurement) {
	p := g.pack
	first := p.firstModel(z)
	e.East, e.North = first.East, first.North
	if p.HasManeuver {
		// Both models are the first-report filter; mu is the long-run share.
		s := p.PEnter + p.PLeave
		e.Models = &[2]Model{first, first}
		e.Mode = [2]float64{p.PLeave / s, p.PEnter / s}
	}
}

// updateFilter applies a later report at time t and returns the filter trace
// records (none with one model).
func (g *Engine) updateFilter(e *Entity, t int64, z Measurement) []Obj {
	p := g.pack
	dt := float64(t-e.LastTime) / 1000
	if !p.HasManeuver {
		m, _ := p.step(Model{e.East, e.North}, dt, p.AccelVar, z)
		e.East, e.North = m.East, m.North
		return nil
	}
	models, mu := *e.Models, e.Mode
	q := [2]float64{p.AccelVar, p.ManeuverVar}
	tr := p.switching(dt)

	// 1. Mixing.
	var c [2]float64
	var mixed [2]Model
	for j := 0; j < 2; j++ {
		c[j] = tr[0][j]*mu[0] + tr[1][j]*mu[1]
		if c[j] == 0 {
			mixed[j] = models[j]
			continue
		}
		w1, w2 := tr[0][j]*mu[0]/c[j], tr[1][j]*mu[1]/c[j]
		mixed[j] = blendModels(w1, w2, models)
	}

	// 2. Predict and update, and 3. likelihood.
	var lambda [2]float64
	for j := 0; j < 2; j++ {
		var gj float64
		models[j], gj = p.step(mixed[j], dt, q[j], z)
		lambda[j] = -0.5 * gj
	}

	// 4. Mode probabilities.
	m := math.Inf(-1)
	for j := 0; j < 2; j++ {
		if c[j] > 0 && lambda[j] > m {
			m = lambda[j]
		}
	}
	var ev [2]float64
	for j := 0; j < 2; j++ {
		if c[j] > 0 {
			ev[j] = c[j] * math.Exp(lambda[j]-m)
		}
	}
	sum := ev[0] + ev[1]
	mu = [2]float64{ev[0] / sum, ev[1] / sum}

	// 5. Combination.
	comb := blendModels(mu[0], mu[1], models)
	e.Models, e.Mode = &models, mu
	e.East, e.North = comb.East, comb.North

	rec := func(test string, j int, v float64) Obj {
		return Obj{"stage": "filter", "a": e.Key, "b": modelNames[j], "test": test, "value": v, "limit": nil, "pass": true}
	}
	return []Obj{rec("likelihood", 0, lambda[0]), rec("likelihood", 1, lambda[1]), rec("mode", 0, mu[0]), rec("mode", 1, mu[1])}
}

// predicted returns copies of both axes of an entity's filter predicted to t
// (Track estimate, Prediction; Two-model filter, Prediction). It never changes e.
func (g *Engine) predicted(e *Entity, t int64) (Axis, Axis) {
	p := g.pack
	dt := float64(t-e.LastTime) / 1000
	if e.Models == nil {
		return e.East.predict(dt, p.AccelVar), e.North.predict(dt, p.AccelVar)
	}
	q := [2]float64{p.AccelVar, p.ManeuverVar}
	var pr [2]Model
	for j := 0; j < 2; j++ {
		pr[j] = Model{e.Models[j].East.predict(dt, q[j]), e.Models[j].North.predict(dt, q[j])}
	}
	m := blendModels(e.Mode[0], e.Mode[1], pr)
	return m.East, m.North
}

// filterSnapshot is the entity's filter fields of the snapshot (correlate.md: Snapshot).
func (e *Entity) filterSnapshot(out Obj) Obj {
	out["filter"] = Obj{"east": e.East.list(), "north": e.North.list()}
	if e.HasTime {
		out["time"] = Obj{"var_east": e.TimeVarEast, "var_north": e.TimeVarNorth}
	}
	if e.Models != nil {
		models := Obj{}
		for j, name := range modelNames {
			models[name] = Obj{"east": e.Models[j].East.list(), "north": e.Models[j].North.list()}
		}
		out["models"] = models
		out["mode"] = []any{e.Mode[0], e.Mode[1]}
	}
	return out
}

// restartTest runs the restart test of correlate.md Restart for a later report
// at time t, appending its trace record, and reports whether the report may
// update the filter (true also when the pack has no restart line).
func (g *Engine) restartTest(e *Entity, t int64, z Measurement, trace *[]Obj) bool {
	p := g.pack
	if !p.HasRestart {
		return true
	}
	pe, pn := g.predicted(e, t)
	// z.REast, z.RNorth are the report's measurement variance (Track estimate),
	// found from this same prediction's velocity; no timing variance is added
	// to the prediction here.
	de, dn := z.East-pe.P, z.North-pn.P
	d2 := de*de/(pe.PP+z.REast) + dn*dn/(pn.PP+z.RNorth)
	pass := d2 < p.RestartGate
	*trace = append(*trace, Obj{"stage": "filter", "a": e.Key, "b": nil, "test": "restart", "value": d2, "limit": p.RestartGate, "pass": pass})
	return pass
}
