package fuse

import (
	"goat-correlator/engines/go/model"
)

// normalize removes every key that correlate.md Reports treats as absent, and a
// `fuse.group` that is not a non-empty string (Reports: the normalized report).
func normalize(report map[string]any) map[string]any {
	out := model.CleanOptional(report)
	if g, ok := out["fuse.group"].(string); !ok || g == "" {
		delete(out, "fuse.group")
	}
	return out
}

// Ingest takes one report (Reports, Groups). A report gives no trace.
func (g *Engine) Ingest(report map[string]any) (events, trace []Obj) {
	trace = []Obj{}

	// Reports: a missing required key rejects the report.
	if k := model.MissingKey(report); k != "" {
		return []Obj{model.Reject(k)}, trace
	}
	source := report["track.source_id"].(string)
	key := source + "/" + report["uid"].(string)
	t, _ := model.ToInt(report["time_ms"])

	// Reports: a report earlier than the entity's last is ignored; equal is accepted.
	e := g.entities[key]
	if e != nil && t < e.LastTime {
		return []Obj{{"ev": "stale-report", "entity": key, "time_ms": t, "last_time_ms": e.LastTime}}, trace
	}

	r := normalize(report)
	group, _ := r["fuse.group"].(string)

	// correlate.md Frame: the first accepted report fixes the reference.
	lat, _ := model.ToFloat(r["lat"])
	lon, _ := model.ToFloat(r["lon"])
	if g.frame == nil {
		g.frame = &model.Frame{Lat0: lat, Lon0: lon}
	}
	east, north := g.frame.ToPlane(lat, lon)

	// correlate.md Track estimate: measurement, first report or later report.
	p := g.pack
	ce, ok := model.ToFloat(r["ce"])
	if !ok {
		ce = p.DefaultCeM
	}
	course, hasCourse := model.ToFloat(r["course"])
	speed, hasSpeed := model.ToFloat(r["speed_ms"])
	hasVel := hasCourse && hasSpeed
	var ve, vn float64
	if hasVel {
		ve, vn = model.Velocity(course, speed)
	}

	z := model.Measurement{East: east, North: north, REast: ce * ce, RNorth: ce * ce, HasVel: hasVel, VE: ve, VN: vn}
	if e == nil {
		first := p.First(z)
		e = &Entity{Key: key, Source: source, East: first.East, North: first.North}
		g.entities[key] = e
		events = []Obj{{"ev": "new", "entity": key, "group": model.OrNull(group)}}
	} else {
		pe, pn := e.predicted(t, p.AccelVar)
		m := p.Update(model.Model{East: pe, North: pn}, z)
		e.East, e.North = m.East, m.North
		events = []Obj{}
		// Groups: a move is applied when the report is accepted, after the filter update.
		if group != e.Group {
			events = append(events, Obj{"ev": "move", "entity": key, "from": model.OrNull(e.Group), "to": model.OrNull(group)})
		}
	}
	e.LastTime, e.Group, e.Report = t, group, r
	return events, trace
}
