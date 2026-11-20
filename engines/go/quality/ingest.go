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
		rec.timeState = &ts
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
		rr := r.ce * r.ce
		de, dn := east-predE.P, north-predN.P
		se, sn := predE.PP+rr, predN.PP+rr
		nis := de*de/se + dn*dn/sn
		rec.nis = &nis
		tr = append(tr, trace.Sample(r.key, "nis", nis, de, dn, se, sn))
	}
	if rec.order == orderAdvance && r.hasSpeed {
		dt := float64(r.t-e.last) / 1000
		implied := math.Hypot(east-e.lastPos[0], north-e.lastPos[1]) / dt
		speedErr := math.Abs(implied - r.speed)
		rec.speedErr = &speedErr
		tr = append(tr, trace.Sample(r.key, "speed_err", speedErr, implied, r.speed))
	}

	// Create the entity, or update its filter, last and last_pos
	// (correlate.md, Track estimate).
	var ve, vn float64
	if rec.vel {
		ve, vn = r.speed*math.Sin(model.Rad(r.course)), r.speed*math.Cos(model.Rad(r.course))
	}
	switch rec.order {
	case orderFirst:
		vv := p.UnknownVelMs * p.UnknownVelMs
		if rec.vel {
			vv = p.VelSigmaMs * p.VelSigmaMs
		}
		e = &entity{key: r.key, source: r.source,
			east:  model.Axis{P: east, V: ve, PP: r.ce * r.ce, VV: vv},
			north: model.Axis{P: north, V: vn, PP: r.ce * r.ce, VV: vv}}
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
	return events, tr
}
