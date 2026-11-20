package quality

import (
	"math"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Ingest takes one report (spec: Ingest).
func (g *Engine) Ingest(report map[string]any) (events, tr []Obj) {
	// Check the required keys; a reject ends it.
	r, missing := g.read(report)
	if missing != "" {
		return []Obj{model.Reject(missing)}, []Obj{}
	}
	events, tr = []Obj{}, []Obj{}
	p := g.pack

	// Set the reference if there is none (spec: Frame and filter).
	if g.ref == nil {
		g.ref = &model.Frame{Lat0: r.lat, Lon0: r.lon}
	}
	east, north := g.ref.ToPlane(r.lat, r.lon)

	// Find the order (spec: Order).
	e := g.entities[r.key]
	rec := record{timeMs: r.t, ce: r.hasCe, vel: r.hasCourse && r.hasSpeed, hae: r.hasHae}
	switch {
	case e == nil:
		rec.order, rec.wt = orderFirst, r.t
		tr = append(tr, trace.Sample(r.key, "order", orderFirst, r.t, nil))
	default:
		switch {
		case r.t > e.last:
			rec.order, rec.wt = orderAdvance, r.t
		case r.t == e.last:
			rec.order, rec.wt = orderDuplicate, e.last
		default:
			rec.order, rec.wt = orderOutOfOrder, e.last
		}
		tr = append(tr, trace.Sample(r.key, "order", rec.order, r.t, e.last))
	}

	// Build the input clock and the source latest, from the entities as they
	// are before this report (spec: Input clock).
	clock := g.inputClock(r.source)
	latest, hasLatest := g.sourceLatest(r.source)
	tq := g.resolveTimeQuality(r.source, report)

	// Take the samples, in the order of spec: Ingest.
	var predE, predN model.Axis
	if rec.order == orderAdvance {
		interval := r.t - e.last
		rec.interval = &interval
		tr = append(tr, trace.Sample(r.key, "interval", interval, r.t, e.last))
	}
	if r.hasReceived {
		latency := r.received - r.t
		rec.latency = &latency
		tr = append(tr, trace.Sample(r.key, "latency", latency, r.received, r.t))
	}
	if clock != nil {
		rec.lateness = lateness(clock, r.t)
		tr = append(tr, trace.Sample(r.key, "lateness", rec.lateness, clock, r.t))
	}
	if te, stated := tq.timeError(); stated {
		rec.timeError = &te
		tr = append(tr, trace.Sample(r.key, "time_error", te, tq.errorReport, tq.errorDefault))
	}
	if ts, stated := tq.timeState(); stated {
		rec.timeState, rec.stateCode = &ts, timeStateCodes[ts]
		tr = append(tr, trace.Sample(r.key, "time_state", ts, tq.stateReport, tq.stateDefault))
	}
	sourceOrder := "in-order"
	var latestInput any // null when the source has no entity
	if hasLatest {
		latestInput = latest
		if r.t < latest {
			sourceOrder = "out-of-order"
		}
	}
	rec.sourceOutOfOrder = sourceOrder == "out-of-order"
	tr = append(tr, trace.Sample(r.key, "source_order", sourceOrder, r.t, latestInput))
	if rec.order == orderAdvance {
		dt := float64(r.t-e.last) / 1000
		predE, predN = e.east.Predict(dt, p.AccelVar), e.north.Predict(dt, p.AccelVar)
		nis, de, dn, se, sn := nisOf(east, north, predE, predN, r.ce*r.ce)
		rec.nis = &nis
		tr = append(tr, trace.Sample(r.key, "nis", nis, de, dn, se, sn))
	}
	if rec.order == orderAdvance && r.hasSpeed {
		dt := float64(r.t-e.last) / 1000
		speedErr, implied := speedErrOf(east-e.lastPos[0], north-e.lastPos[1], dt, r.speed)
		rec.speedErr = &speedErr
		tr = append(tr, trace.Sample(r.key, "speed_err", speedErr, implied, r.speed))
	}

	// Create the entity, or update its filter, last and last_pos
	// (correlate.md, Track estimate).
	z := model.Measurement{East: east, North: north, REast: r.ce * r.ce, RNorth: r.ce * r.ce, HasVel: rec.vel}
	if rec.vel {
		z.VE, z.VN = model.Velocity(r.course, r.speed)
	}
	switch rec.order {
	case orderFirst:
		first := p.First(z)
		e = &entity{key: r.key, source: r.source, east: first.East, north: first.North}
		g.entities[r.key] = e
		events = append(events, Obj{"ev": "new", "entity": r.key})
	case orderAdvance:
		m := p.Update(model.Model{East: predE, North: predN}, z)
		e.east, e.north = m.East, m.North
	}
	if rec.order == orderFirst || rec.order == orderAdvance {
		e.last, e.lastPos = r.t, [2]float64{east, north}
	}

	// Append the record; emit pass.
	e.window = append(e.window, rec)
	events = append(events, g.forward(e, report, r))
	return events, tr
}

// nisOf is the normalized innovation squared of a position (east, north)
// against a prediction with measurement variance r on both axes, with its
// inputs de, dn, se, sn (Samples: nis).
func nisOf(east, north float64, pe, pn model.Axis, r float64) (nis, de, dn, se, sn float64) {
	de, dn = east-pe.P, north-pn.P
	se, sn = pe.PP+r, pn.PP+r
	return de*de/se + dn*dn/sn, de, dn, se, sn
}

// speedErrOf is the speed error of a report that moved (de, dn) in dt
// seconds and reports speed, with the implied speed (Samples: speed_err).
func speedErrOf(de, dn, dt, speed float64) (speedErr, implied float64) {
	implied = math.Hypot(de, dn) / dt
	return math.Abs(implied - speed), implied
}
