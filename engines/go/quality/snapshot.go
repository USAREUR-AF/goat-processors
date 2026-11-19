package quality

func optInt(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

func optFloat(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

// Snapshot returns the whole state (spec: Snapshot).
func (g *Engine) Snapshot() Obj {
	var ref, lastTick any
	if g.ref != nil {
		ref = []any{g.ref[0], g.ref[1]}
	}
	if g.lastTick != nil {
		lastTick = *g.lastTick
	}
	entities := Obj{}
	for key, e := range g.entities {
		window := []any{}
		for _, rec := range e.window {
			window = append(window, Obj{
				"wt": rec.wt, "time_ms": rec.timeMs, "order": rec.order,
				"interval": optInt(rec.interval), "latency": optInt(rec.latency),
				"nis": optFloat(rec.nis), "speed_err": optFloat(rec.speedErr),
				"ce": rec.ce, "vel": rec.vel, "hae": rec.hae,
			})
		}
		entities[key] = Obj{
			"source":       e.source,
			"last_time_ms": e.last,
			"last_pos":     []any{e.lastPos[0], e.lastPos[1]},
			"filter":       Obj{"east": e.east.List(), "north": e.north.List()},
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
