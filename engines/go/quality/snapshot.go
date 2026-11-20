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
