package assign

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
)

// Snapshot (spec: Snapshot).

func systemsObj(mb Membership) Obj {
	out := Obj{}
	for k, v := range mb.Systems {
		out[k] = model.Strings(v)
	}
	return out
}

// Snapshot returns the whole state of method assign.
func (m *Method) Snapshot() Obj {
	c := m.core
	ents := Obj{}
	for _, k := range c.Keys() {
		var sys any
		if s := m.system[k]; s != "" {
			sys = s
		}
		ents[k] = c.EntitySnapshot(k, Obj{"system": sys})
	}
	snap := Obj{"ref": snapshot.Ref(c.Frame()), "entities": ents, "systems": systemsObj(m.committed),
		"next_system": int64(m.committed.Next), "reported": model.Strings(model.SortedKeys(m.reported))}
	if m.p.HasRestart {
		snap["restarted"] = model.Strings(model.SortedKeys(m.restarted))
	}
	if m.p.HasBias {
		snap["bias"] = m.biasSnapshot()
	}
	if m.p.Window == 1 {
		return snap
	}
	retiring := []any{}
	for _, k := range model.SortedKeys(m.retiring) {
		retiring = append(retiring, k)
	}
	histories := []any{}
	for _, h := range m.histories {
		records := []any{}
		for _, r := range h.Records {
			choices := []any{}
			for _, ch := range r.Choices {
				choices = append(choices, []any{ch.Entity, ch.Chosen})
			}
			events := []any{}
			for _, e := range r.Events {
				events = append(events, e)
			}
			records = append(records, Obj{"cost": r.Cost, "choices": choices, "events": events,
				"systems": systemsObj(r.M), "next_system": int64(r.M.Next)})
		}
		histories = append(histories, Obj{"total": h.total(), "records": records})
	}
	snap["retiring"], snap["histories"] = retiring, histories
	return snap
}

// biasSnapshot maps each stored pair key to its state.
func (m *Method) biasSnapshot() Obj {
	out := Obj{}
	for k, st := range m.bias {
		o := Obj{"east": st.OEast, "weight_east": st.WEast, "north": st.ONorth,
			"weight_north": st.WNorth, "var": st.Var, "pairs": st.Pairs}
		if m.p.HasTimeOffset {
			sums := make([]any, 8)
			for i, v := range st.Sums {
				sums[i] = v
			}
			o["time_offset_ms"], o["sums"] = st.Tau*1000, sums
		}
		out[k] = o
	}
	return out
}
