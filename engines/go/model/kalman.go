package model

import "math"

// The constant-velocity filter, one axis at a time (spec/correlate.md:
// Track estimate). Every step is a pure function of an Axis value.

// Axis is one axis of the filter: position, velocity and the covariance
// entries pp, pv, vv.
type Axis struct{ P, V, PP, PV, VV float64 }

// Predict is step 1, also the prediction to a time; dt in seconds, q the
// acceleration variance.
func (a Axis) Predict(dt, q float64) Axis {
	return Axis{
		P:  a.P + a.V*dt,
		V:  a.V,
		PP: a.PP + 2*dt*a.PV + dt*dt*a.VV + q*dt*dt*dt*dt/4,
		PV: a.PV + dt*a.VV + q*dt*dt*dt/2,
		VV: a.VV + q*dt*dt,
	}
}

// UpdatePosInnovation is step 2, the position update with measurement z
// and variance r; it also returns the innovation y and its variance s.
func (a Axis) UpdatePosInnovation(z, r float64) (Axis, float64, float64) {
	s := a.PP + r
	k1, k2 := a.PP/s, a.PV/s
	y := z - a.P
	return Axis{
		P:  a.P + k1*y,
		V:  a.V + k2*y,
		PP: (1 - k1) * a.PP,
		PV: (1 - k1) * a.PV,
		VV: a.VV - k2*a.PV,
	}, y, s
}

// UpdateVelInnovation is step 3, the velocity update with measurement z
// and variance r; it also returns the innovation y and its variance s.
func (a Axis) UpdateVelInnovation(z, r float64) (Axis, float64, float64) {
	s := a.VV + r
	k1, k2 := a.PV/s, a.VV/s
	y := z - a.V
	return Axis{
		P:  a.P + k1*y,
		V:  a.V + k2*y,
		PP: a.PP - k1*a.PV,
		PV: (1 - k2) * a.PV,
		VV: (1 - k2) * a.VV,
	}, y, s
}

// UpdatePos is step 2 without the innovation.
func (a Axis) UpdatePos(z, r float64) Axis {
	u, _, _ := a.UpdatePosInnovation(z, r)
	return u
}

// UpdateVel is step 3 without the innovation.
func (a Axis) UpdateVel(z, r float64) Axis {
	u, _, _ := a.UpdateVelInnovation(z, r)
	return u
}

// List is the snapshot form [p, v, pp, pv, vv].
func (a Axis) List() []any { return []any{a.P, a.V, a.PP, a.PV, a.VV} }

// Model is one constant-velocity filter, both axes.
type Model struct{ East, North Axis }

// Predict predicts both axes.
func (m Model) Predict(dt, q float64) Model {
	return Model{m.East.Predict(dt, q), m.North.Predict(dt, q)}
}

// FilterParams are the four parameters of the filter line (Track estimate).
type FilterParams struct {
	AccelVar     float64 // q
	DefaultCeM   float64 // ce of a report without one
	VelSigmaMs   float64 // velocity measurement sigma
	UnknownVelMs float64 // velocity sigma of a first report without a velocity
}

// Measurement is what one report gives the filter, in the plane.
type Measurement struct {
	East, North float64 // position, m
	REast       float64 // r_east, the position variance east (Measurement variance)
	RNorth      float64 // r_north, the position variance north
	HasVel      bool
	VE, VN      float64 // velocity, m/s, when HasVel
}

// First is the filter of a first report (Track estimate, First report).
func (p FilterParams) First(z Measurement) Model {
	vv := p.UnknownVelMs * p.UnknownVelMs
	if z.HasVel {
		vv = p.VelSigmaMs * p.VelSigmaMs
	}
	return Model{
		East:  Axis{P: z.East, V: z.VE, PP: z.REast, VV: vv},
		North: Axis{P: z.North, V: z.VN, PP: z.RNorth, VV: vv},
	}
}

// Update is steps 2 and 3 on a predicted model: the position updates, then
// with a velocity the velocity updates.
func (p FilterParams) Update(pred Model, z Measurement) Model {
	e, n := pred.East.UpdatePos(z.East, z.REast), pred.North.UpdatePos(z.North, z.RNorth)
	if z.HasVel {
		r := p.VelSigmaMs * p.VelSigmaMs
		e, n = e.UpdateVel(z.VE, r), n.UpdateVel(z.VN, r)
	}
	return Model{e, n}
}

// Step is steps 1 to 3 with acceleration variance q, and also returns g,
// the sum of y*y/s + ln(s) over the scalar updates in the order east
// position, north position, east velocity, north velocity (Two-model
// filter, step 3).
func (p FilterParams) Step(m Model, dt, q float64, z Measurement) (Model, float64) {
	g := 0.0
	term := func(y, s float64) { g = g + (y*y/s + math.Log(s)) }

	e, n := m.East.Predict(dt, q), m.North.Predict(dt, q)
	var y, s float64
	e, y, s = e.UpdatePosInnovation(z.East, z.REast)
	term(y, s)
	n, y, s = n.UpdatePosInnovation(z.North, z.RNorth)
	term(y, s)
	if z.HasVel {
		r := p.VelSigmaMs * p.VelSigmaMs
		e, y, s = e.UpdateVelInnovation(z.VE, r)
		term(y, s)
		n, y, s = n.UpdateVelInnovation(z.VN, r)
		term(y, s)
	}
	return Model{e, n}, g
}

// Mahalanobis is the squared statistical distance of a position (e, n)
// from a prediction (pe, pn), with r_east and r_north added to the
// predicted pp on each axis (correlate.md: Tests, Restart).
func Mahalanobis(e, n float64, pe, pn Axis, rEast, rNorth float64) float64 {
	de, dn := e-pe.P, n-pn.P
	return de*de/(pe.PP+rEast) + dn*dn/(pn.PP+rNorth)
}
