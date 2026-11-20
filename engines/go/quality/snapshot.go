package quality

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
)

// Snapshot returns the whole state (spec: Snapshot).
func (g *Engine) Snapshot() Obj {
	ref := snapshot.Ref(g.ref)
	var lastTick any
	if g.lastTick != nil {
		lastTick = *g.lastTick
	}
	entities := Obj{}
	for key, e := range g.entities {
		window := []any{}
		for _, rec := range e.window {
			window = append(window, Obj{
				"wt": rec.wt, "time_ms": rec.timeMs, "order": rec.order,
				"interval": snapshot.OptInt(rec.interval), "latency": snapshot.OptInt(rec.latency),
				"lateness": rec.lateness, "source_out_of_order": rec.sourceOutOfOrder,
				"time_error": snapshot.OptFloat(rec.timeError), "time_state": snapshot.OptString(rec.timeState),
				"nis": snapshot.OptFloat(rec.nis), "speed_err": snapshot.OptFloat(rec.speedErr),
				"ce": rec.ce, "vel": rec.vel, "hae": rec.hae,
			})
		}
		entities[key] = Obj{
			"source":       e.source,
			"last_time_ms": e.last,
			"last_pos":     []any{e.lastPos[0], e.lastPos[1]},
			"filter":       snapshot.Filter(model.Model{East: e.east, North: e.north}),
			"window":       window,
		}
	}
	rules := Obj{}
	for i, rule := range g.pack.Rules {
		states := Obj{}
		for subject, st := range g.states[i] {
			states[subject] = Obj{"count": st.count, "active": st.active}
		}
		rules[rule.Name] = states
	}
	return Obj{"ref": ref, "last_tick": lastTick, "entities": entities, "rules": rules}
}

// Restore returns an engine for p in the state of a snapshot, as Snapshot
// returns it or as JSON decodes it (numbers as json.Number): it continues
// exactly as the engine that took the snapshot.
func Restore(p *Pack, snap map[string]any) (*Engine, error) {
	var d snapshot.Decoder
	g := New(p)
	g.ref = d.Ref(snap["ref"])
	g.lastTick = d.OptInt("last_tick", snap["last_tick"])
	for key, v := range d.Object("entities", snap["entities"]) {
		o := d.Object(key, v)
		f := d.Filter("filter", o["filter"])
		pos := d.List("last_pos", o["last_pos"])
		e := &entity{key: key, source: d.String("source", o["source"]), last: d.Int("last_time_ms", o["last_time_ms"]),
			east: f.East, north: f.North}
		if len(pos) == 2 {
			e.lastPos = [2]float64{d.Float("last_pos", pos[0]), d.Float("last_pos", pos[1])}
		} else {
			d.Fail("last_pos", o["last_pos"])
		}
		for _, rv := range d.List("window", o["window"]) {
			r := d.Object("window", rv)
			e.window = append(e.window, record{
				wt: d.Int("wt", r["wt"]), timeMs: d.Int("time_ms", r["time_ms"]), order: d.String("order", r["order"]),
				interval: d.OptInt("interval", r["interval"]), latency: d.OptInt("latency", r["latency"]),
				lateness: restoreLateness(&d, r["lateness"]), sourceOutOfOrder: d.Bool("source_out_of_order", r["source_out_of_order"]),
				timeError: d.OptFloat("time_error", r["time_error"]), timeState: d.OptString("time_state", r["time_state"]),
				nis: d.OptFloat("nis", r["nis"]), speedErr: d.OptFloat("speed_err", r["speed_err"]),
				ce: d.Bool("ce", r["ce"]), vel: d.Bool("vel", r["vel"]), hae: d.Bool("hae", r["hae"]),
			})
		}
		for i := range e.window {
			if st := e.window[i].timeState; st != nil {
				e.window[i].stateCode = timeStateCodes[*st]
			}
		}
		g.entities[key] = e
	}
	rules := d.Object("rules", snap["rules"])
	for i, rule := range p.Rules {
		for subject, sv := range d.Object(rule.Name, rules[rule.Name]) {
			s := d.Object(subject, sv)
			g.states[i][subject] = &ruleState{count: d.Int("count", s["count"]), active: d.Bool("active", s["active"])}
		}
	}
	if d.Err != nil {
		return nil, d.Err
	}
	return g, nil
}

// restoreLateness reads a lateness sample: null, an integer, or a binary64.
func restoreLateness(d *snapshot.Decoder, v any) any {
	if v == nil {
		return nil
	}
	if model.IsInt(v) {
		return d.Int("lateness", v)
	}
	return d.Float("lateness", v)
}
