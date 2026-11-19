package correlator

// Sensor bias (spec/correlate-assign.md, Sensor bias): one position offset per
// unordered pair of sources, used to move one source's predictions into the
// other's frame, and learned at each tick from the committed system tracks.

// BiasState is the stored state of one pair "<S>|<T>" (S before T in key
// order): how far T's positions sit east and north of S's.
type BiasState struct {
	OEast, WEast   float64 // offset o and weight sum w, east
	ONorth, WNorth float64 // offset o and weight sum w, north
	Var            float64 // var, both axes
	Pairs          int64   // n, the count of accepted pairs
}

// biasState returns the state of pair key, or the state a pair with none
// reads as: o = 0, w = 0, var = s², n = 0 (State).
func (g *Engine) biasState(key string) BiasState {
	if st, ok := g.bias[key]; ok {
		return *st
	}
	s := g.pack.BiasSigma
	return BiasState{Var: s * s}
}

// moveInto moves B's predicted axes into A's frame (Moving B into A's frame).
// Without the bias line, or for two entities of one source, nothing moves.
func (g *Engine) moveInto(b, a *Entity, be, bn Axis) (Axis, Axis) {
	if !g.pack.HasBias || a.Source == b.Source {
		return be, bn
	}
	if b.Source < a.Source {
		st := g.biasState(b.Source + "|" + a.Source)
		be.P, be.PP = be.P+st.OEast, be.PP+st.Var
		bn.P, bn.PP = bn.P+st.ONorth, bn.PP+st.Var
	} else {
		st := g.biasState(a.Source + "|" + b.Source)
		be.P, be.PP = be.P-st.OEast, be.PP+st.Var
		bn.P, bn.PP = bn.P-st.ONorth, bn.PP+st.Var
	}
	return be, bn
}

// predictedFor returns B predicted to A's time and moved into A's frame: the
// prediction every test between A and B reads (correlate.md Tests; Sensor bias).
func (g *Engine) predictedFor(b, a *Entity) (Axis, Axis) {
	be, bn := g.predicted(b, a.LastTime)
	return g.moveInto(b, a, be, bn)
}

// updateBias runs the Update of Sensor bias at now over the committed
// membership, for pairs with at least one member among the tick's rows, and
// returns its trace records.
func (g *Engine) updateBias(now int64, rows map[string]bool) []Obj {
	p := g.pack
	out := []Obj{}
	for _, name := range g.committed.order() {
		var members []*Entity // not retiring, key order
		for _, k := range g.committed.Systems[name] {
			if e := g.entities[k]; !e.Retiring {
				members = append(members, e)
			}
		}
		for i, x := range members {
			for _, y := range members[i+1:] {
				if x.Source == y.Source || !(rows[x.Key] || rows[y.Key]) {
					continue
				}
				// 1. ES has the source first in key order; predict both to now (not moved).
				es, et := x, y
				if et.Source < es.Source {
					es, et = et, es
				}
				key := es.Source + "|" + et.Source
				st := g.biasState(key)
				se, sn := g.predicted(es, now)
				te, tn := g.predicted(et, now)
				ye, re := te.P-se.P, se.PP+te.PP
				yn, rn := tn.P-sn.P, sn.PP+tn.PP

				// 2. d² with the pair's state.
				de, dn := ye-st.OEast, yn-st.ONorth
				d2 := de*de/(st.Var+re) + dn*dn/(st.Var+rn)

				// 3. Accept below the gate.
				accepted := d2 < p.BiasGate
				if accepted {
					st.Pairs++
					st.Var = p.BiasSigma * p.BiasSigma / float64(st.Pairs+1)
					if floor := p.BiasFloor * p.BiasFloor; st.Var < floor {
						st.Var = floor
					}
					st.WEast = st.WEast + 1/re
					st.OEast = st.OEast + ((1/re)/st.WEast)*(ye-st.OEast)
					st.WNorth = st.WNorth + 1/rn
					st.ONorth = st.ONorth + ((1/rn)/st.WNorth)*(yn-st.ONorth)
					stored := st
					g.bias[key] = &stored
				}

				// 4. Trace, with the state after step 3.
				out = append(out, Obj{"stage": "bias", "a": x.Key, "b": y.Key, "test": "offset",
					"value": d2, "limit": p.BiasGate, "pass": accepted,
					"east": st.OEast, "north": st.ONorth, "var": st.Var, "pairs": st.Pairs})
			}
		}
	}
	return out
}

// biasSnapshot maps each stored pair key to its state (Snapshot).
func (g *Engine) biasSnapshot() Obj {
	out := Obj{}
	for k, st := range g.bias {
		out[k] = Obj{"east": st.OEast, "weight_east": st.WEast, "north": st.ONorth,
			"weight_north": st.WNorth, "var": st.Var, "pairs": st.Pairs}
	}
	return out
}
