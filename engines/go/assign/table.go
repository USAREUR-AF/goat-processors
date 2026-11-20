package assign

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Assignment of one source (spec: Assignment of one source) and the fused
// estimate (Fused estimate).

// fused returns the fused estimate of a set of entities at time t, per axis
// (Fused estimate). Only P, V, PP and VV are meaningful. With a frame
// entity A (Cost, frame != ""), each member's predicted pp first gets the
// member's timing variance (correlate.md Track estimate) and then, with the
// pack's bias line, the member is moved into A's frame (Sensor bias); for
// output, frame is "" and neither happens.
func (m *Method) fused(members []string, t int64, frame string) (model.Axis, model.Axis) {
	c := m.core
	var se, sn [4]float64 // sum 1/pp, sum p/pp, sum 1/vv, sum v/vv
	for _, k := range members {
		e, n := c.Predicted(k, t)
		if frame != "" {
			ve, vn := c.TimingVariance(k)
			e, n = model.AddVariance(e, n, ve, vn)
			e, n = m.MoveInto(c.Source(k), c.Source(frame), e, n)
		}
		for _, x := range []struct {
			a model.Axis
			s *[4]float64
		}{{e, &se}, {n, &sn}} {
			x.s[0] += 1 / x.a.PP
			x.s[1] += x.a.P / x.a.PP
			x.s[2] += 1 / x.a.VV
			x.s[3] += x.a.V / x.a.VV
		}
	}
	mk := func(s [4]float64) model.Axis {
		pp, vv := 1/s[0], 1/s[2]
		return model.Axis{P: pp * s[1], V: vv * s[3], PP: pp, VV: vv}
	}
	return mk(se), mk(sn)
}

// cost is d² of entity A against the fused estimate of M at A's time (Cost);
// pp_a is A's filter pp plus A's timing variance.
func (m *Method) cost(a string, members []string) float64 {
	c := m.core
	fe, fn := m.fused(members, c.LastTime(a), a)
	ae, an := c.Filter(a)
	ve, vn := c.TimingVariance(a)
	ae, an = model.AddVariance(ae, an, ve, vn)
	de, dn := ae.P-fe.P, an.P-fn.P
	return de*de/(ae.PP+fe.PP) + dn*dn/(an.PP+fn.PP)
}

// entry is one cell of the table: its cost, or forbidden.
type entry struct {
	cost float64
	ok   bool
}

// table is one source's columns and entries against one membership.
// entries[i] has one cell per column, then the row's alone cell last.
type table struct {
	rows    []string // R, key order
	cols    []string // system tracks, creation order
	entries [][]entry
}

func (t *table) chosenName(j int) string {
	if j == len(t.cols) {
		return "alone"
	}
	return t.cols[j]
}

// buildTable computes source src's columns and entries against membership mb
// (steps 1 and 2), appending the gate records to tr.
func (m *Method) buildTable(src string, rows []string, mb Membership, tr *[]Obj) *table {
	p, c := m.p, m.core
	inR := map[string]bool{}
	for _, k := range rows {
		inR[k] = true
	}

	// 1. Columns: tracks whose others (members not in R) are not empty and hold no entity of S.
	t := &table{rows: rows}
	var others [][]string
	for _, name := range mb.order() {
		var o []string
		ok := true
		for _, k := range mb.Systems[name] {
			if inR[k] {
				continue
			}
			if c.Source(k) == src {
				ok = false
			}
			o = append(o, k)
		}
		if ok && len(o) > 0 {
			t.cols = append(t.cols, name)
			others = append(others, o)
		}
	}

	// 2. Entries.
	for _, ak := range rows {
		own := mb.systemOf(ak)
		row := make([]entry, len(t.cols)+1)
		for j, name := range t.cols {
			pass := true
			for _, bk := range others[j] {
				if !c.Gate(ak, bk, tr) {
					pass = false
					break
				}
			}
			if pass {
				cost := m.cost(ak, others[j])
				if own == name {
					cost -= p.KeepBonus
				}
				row[j] = entry{cost, true}
			}
		}
		alone := p.NewCost
		if own != "" && len(mb.Systems[own]) == 1 {
			alone -= p.KeepBonus
		}
		row[len(t.cols)] = entry{alone, true}
		t.entries = append(t.entries, row)
	}
	return t
}

// costRecords are the trace records of every entry, rows in key order, columns
// in creation order then alone.
func (t *table) costRecords() []Obj {
	var out []Obj
	for i, ak := range t.rows {
		for j, e := range t.entries[i] {
			if e.ok {
				out = append(out, trace.Assign(ak, t.chosenName(j), "cost", e.cost, true))
			} else {
				out = append(out, trace.Assign(ak, t.chosenName(j), "cost", nil, false))
			}
		}
	}
	return out
}

// apply applies an assignment to membership mb, rows in key order (step 4).
func (t *table) apply(mb *Membership, a assignment, events []Obj) []Obj {
	for i, ak := range t.rows {
		own := mb.systemOf(ak)
		if a.choice[i] < len(t.cols) {
			name := t.cols[a.choice[i]]
			if own == name {
				continue
			}
			if own != "" {
				events = mb.leave(ak, "assign", events)
			}
			events = mb.join(ak, name, events)
			continue
		}
		if own != "" && len(mb.Systems[own]) == 1 {
			continue // alone already
		}
		if own != "" {
			events = mb.leave(ak, "assign", events)
		}
		events = mb.start(ak, events)
	}
	return events
}
