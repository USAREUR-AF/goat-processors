package assign

import (
	"math"
	"sort"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Window and On each tick (spec: Window, Events).

// tag adds the given keys to each record, only with a window above 1 (spec: Trace).
func (m *Method) tag(recs []Obj, kv ...any) []Obj {
	if m.p.Window > 1 {
		return trace.Tag(recs, kv...)
	}
	return recs
}

// candidate is one ranked assignment r applied to history h.
type candidate struct {
	h, r  int
	hist  History
	total float64
}

// Tick runs one tick, steps 1 to 6 of Window.
func (m *Method) Tick(now int64) (events, tr []Obj) {
	events, tr = []Obj{}, []Obj{}
	p, c := m.p, m.core
	windowed := p.Window > 1

	// 1. Staleness: every history gets a new record with the stale entities dropped.
	var stale []string
	for _, k := range c.Keys() {
		if !m.retiring[k] && c.Stale(k, now) {
			stale = append(stale, k)
		}
	}
	isStale := map[string]bool{}
	for _, k := range stale {
		isStale[k] = true
	}
	var restarted []string
	for _, k := range model.SortedKeys(m.restarted) {
		if !isStale[k] {
			restarted = append(restarted, k)
		}
	}
	for i, h := range m.histories {
		rec := Record{Choices: []Choice{}, Events: []Obj{}, M: h.latest(m.committed).copy()}
		for _, k := range stale {
			if rec.M.systemOf(k) != "" {
				rec.Events = rec.M.leave(k, "stale", rec.Events)
			}
			rec.Events = append(rec.Events, Obj{"ev": "drop", "entity": k})
		}
		// Each restarted entity that is not stale leaves its system track.
		for _, k := range restarted {
			if rec.M.systemOf(k) != "" {
				rec.Events = rec.M.leave(k, "restart", rec.Events)
			}
		}
		m.histories[i] = History{append(append([]Record(nil), h.Records...), rec)}
	}
	for _, k := range stale {
		m.retiring[k] = true
		delete(m.reported, k)
	}
	m.restarted = map[string]bool{} // no entity is restarted after this step

	// 2. Rows: entities reported since the previous tick, grouped by source.
	bySource := map[string][]string{}
	rows := map[string]bool{}
	for _, k := range model.SortedKeys(m.reported) {
		src := c.Source(k)
		bySource[src] = append(bySource[src], k)
		rows[k] = true
	}
	m.reported = map[string]bool{}

	// 3. Sources, in key order: each history's ranked assignments become candidates.
	for _, src := range model.SortedKeys(bySource) {
		rows := bySource[src]
		var cands []candidate
		for hi, h := range m.histories {
			last := h.Records[len(h.Records)-1]
			var gates []Obj
			t := m.buildTable(src, rows, last.M, &gates)
			tr = append(tr, m.tag(gates, "h", hi)...)
			tr = append(tr, m.tag(t.costRecords(), "h", hi)...)
			for ri, a := range t.ranked(int(p.Hypotheses)) {
				rec := Record{
					Cost:    last.Cost + a.total,
					Choices: append([]Choice(nil), last.Choices...),
					Events:  append([]Obj(nil), last.Events...),
					M:       last.M.copy(),
				}
				var choices []Obj
				for i, ak := range rows {
					chosen := t.chosenName(a.choice[i])
					rec.Choices = append(rec.Choices, Choice{ak, chosen})
					choices = append(choices, trace.Assign(ak, chosen, "choice", t.entries[i][a.choice[i]].cost, true))
				}
				tr = append(tr, m.tag(choices, "h", hi, "r", ri)...)
				rec.Events = t.apply(&rec.M, a, rec.Events)
				recs := append(append([]Record(nil), h.Records[:len(h.Records)-1]...), rec)
				nh := History{recs}
				cands = append(cands, candidate{hi, ri, nh, nh.total()})
			}
		}
		// Candidates were built in (h, r) order; a stable sort by total gives total, h, r.
		sort.SliceStable(cands, func(a, b int) bool { return cands[a].total < cands[b].total })
		// The first k are kept; with margin, only those within cut = best + m.
		var cut any
		if p.HasMargin {
			cut = cands[0].total + p.Margin
		}
		m.histories = m.histories[:0:0]
		for i, cd := range cands {
			kept := i < int(p.Hypotheses)
			if p.HasMargin {
				kept = kept && cd.total <= cut.(float64)
			}
			if kept {
				m.histories = append(m.histories, cd.hist)
			}
			if windowed {
				rec := trace.History(cd.h, cd.r, "total", cd.total, kept)
				rec["limit"] = cut
				tr = append(tr, rec)
			}
		}
	}

	// 4. Commit, when the best history has n records.
	if int64(len(m.histories[0].Records)) == p.Window {
		best := m.histories[0].Records[0]
		var kept []History
		for i, h := range m.histories {
			keep := sameChoices(h.Records[0].Choices, best.Choices)
			if windowed {
				tr = append(tr, trace.History(i, nil, "commit", h.total(), keep))
			}
			if keep {
				kept = append(kept, History{append([]Record(nil), h.Records[1:]...)})
			}
		}
		m.histories = kept
		events = append(events, best.Events...)
		m.committed = best.M
		for _, ev := range best.Events {
			if ev["ev"] == "drop" {
				k := ev["entity"].(string)
				c.Drop(k)
				delete(m.retiring, k)
			}
		}
		m.system = map[string]string{}
		for _, k := range c.Keys() {
			if s := m.committed.systemOf(k); s != "" {
				m.system[k] = s
			}
		}
	}

	// 5. Bias: the update of Sensor bias, over the committed membership.
	if p.HasBias {
		tr = append(tr, m.updateBias(now, rows)...)
	}

	// 6. Output: the committed system tracks (with margin, the best history's
	// latest ones), then the best history's provisional ones.
	best := m.histories[0].latest(m.committed)
	reported := m.committed
	if p.HasMargin {
		reported = best
	}
	for _, name := range reported.order() {
		events = append(events, m.systemEvent(name, reported.Systems[name], now))
	}
	if windowed {
		for _, name := range best.order() {
			events = append(events, Obj{"ev": "provisional", "system": name, "members": model.Strings(best.Systems[name])})
		}
	}
	return events, tr
}

// systemEvent is the fused estimate of all a system track's members at now (step 6).
func (m *Method) systemEvent(name string, members []string, now int64) Obj {
	c := m.core
	fe, fn := m.fused(members, now, "")
	lat, lon := c.Frame().ToDegrees(fe.P, fn.P)
	ev := Obj{"ev": "system", "system": name, "members": model.Strings(members),
		"lat": lat, "lon": lon, "course": model.Course(fe.V, fn.V), "speed_ms": math.Hypot(fe.V, fn.V)}
	src := ""
	var hae float64
	for _, k := range members { // key order: a tie keeps the earlier
		if h, ok := c.Hae(k); ok && (src == "" || c.LastTime(k) > c.LastTime(src)) {
			src, hae = k, h
		}
	}
	if src != "" {
		ev["hae"] = hae
	}
	return ev
}
