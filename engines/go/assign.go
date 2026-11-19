package correlator

import (
	"fmt"
	"math"
	"sort"
	"strconv"
)

// Method assign (spec/correlate-assign.md): system tracks, per-source ranked
// assignments at each tick, kept as up to k histories over a window of n ticks,
// and the inverse-variance fused estimate.

// ---------------------------------------------------------------------------
// Memberships (spec: Memberships)

// Membership is one picture of the system tracks.
type Membership struct {
	Systems map[string][]string // system track name -> members in key order
	Next    int                 // the counter that names the next system track
}

func newMembership() Membership { return Membership{Systems: map[string][]string{}, Next: 1} }

func (m Membership) copy() Membership {
	c := Membership{Systems: make(map[string][]string, len(m.Systems)), Next: m.Next}
	for k, v := range m.Systems {
		c.Systems[k] = append([]string(nil), v...)
	}
	return c
}

// order returns the system track names in creation order, which is the order of
// their numbers.
func (m Membership) order() []string {
	names := sortedKeys(m.Systems)
	num := func(s string) int { n, _ := strconv.Atoi(s[1:]); return n }
	sort.Slice(names, func(i, j int) bool { return num(names[i]) < num(names[j]) })
	return names
}

// systemOf returns the system track holding entity k, or "".
func (m Membership) systemOf(k string) string {
	for name, members := range m.Systems {
		for _, e := range members {
			if e == k {
				return name
			}
		}
	}
	return ""
}

// leave removes k from its system track (event leave); a track left empty ends (event end).
func (m *Membership) leave(k, reason string, events []Obj) []Obj {
	name := m.systemOf(k)
	events = append(events, Obj{"ev": "leave", "system": name, "entity": k, "reason": reason})
	var rest []string
	for _, e := range m.Systems[name] {
		if e != k {
			rest = append(rest, e)
		}
	}
	if len(rest) > 0 {
		m.Systems[name] = rest
		return events
	}
	delete(m.Systems, name)
	return append(events, Obj{"ev": "end", "system": name})
}

// join adds k to system track name (event join).
func (m *Membership) join(k, name string, events []Obj) []Obj {
	members := append(m.Systems[name], k)
	sort.Strings(members)
	m.Systems[name] = members
	return append(events, Obj{"ev": "join", "system": name, "entity": k})
}

// start makes a new system track holding k alone, named by the counter (event start).
func (m *Membership) start(k string, events []Obj) []Obj {
	name := fmt.Sprintf("s%d", m.Next)
	m.Next++
	m.Systems[name] = []string{k}
	return append(events, Obj{"ev": "start", "system": name, "entity": k})
}

// Choice is one [entity, chosen] pair of a record; chosen is a system track or "alone".
type Choice struct{ Entity, Chosen string }

// Record is one pending tick of a history.
type Record struct {
	Cost    float64
	Choices []Choice
	Events  []Obj
	M       Membership // the membership after that tick
}

// History is a list of pending ticks, oldest first.
type History struct{ Records []Record }

// total is the sum, left to right from 0, of the records' cost, oldest first.
func (h History) total() float64 {
	t := 0.0
	for _, r := range h.Records {
		t = t + r.Cost
	}
	return t
}

// latest returns the membership of the newest record, or the committed one.
func (h History) latest(committed Membership) Membership {
	if len(h.Records) == 0 {
		return committed
	}
	return h.Records[len(h.Records)-1].M
}

func sameChoices(a, b []Choice) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Assignment of one source (spec: Assignment of one source)

// fused returns the fused estimate of a set of entities at time t, per axis
// (Fused estimate). Only P, V, PP and VV are meaningful. With a non-nil frame
// entity A (Cost), each member's predicted pp first gets the member's timing
// variance (correlate.md Track estimate) and then, with the pack's bias line,
// the member is moved into A's frame (Sensor bias); for output, frame is nil
// and neither happens.
func (g *Engine) fused(members []string, t int64, frame *Entity) (Axis, Axis) {
	var se, sn [4]float64 // sum 1/pp, sum p/pp, sum 1/vv, sum v/vv
	for _, k := range members {
		e, n := g.predicted(g.entities[k], t)
		if frame != nil {
			e, n = withTimingVariance(g.entities[k], e, n)
			e, n = g.moveInto(g.entities[k], frame, e, n)
		}
		for _, x := range []struct {
			a Axis
			s *[4]float64
		}{{e, &se}, {n, &sn}} {
			x.s[0] += 1 / x.a.PP
			x.s[1] += x.a.P / x.a.PP
			x.s[2] += 1 / x.a.VV
			x.s[3] += x.a.V / x.a.VV
		}
	}
	mk := func(s [4]float64) Axis {
		pp, vv := 1/s[0], 1/s[2]
		return Axis{P: pp * s[1], V: vv * s[3], PP: pp, VV: vv}
	}
	return mk(se), mk(sn)
}

// cost is d² of entity A against the fused estimate of M at A's time (Cost);
// pp_a is A's filter pp plus A's timing variance.
func (g *Engine) cost(a *Entity, members []string) float64 {
	fe, fn := g.fused(members, a.LastTime, a)
	ae, an := withTimingVariance(a, a.East, a.North)
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

// buildTable computes source src's columns and entries against membership m
// (steps 1 and 2), appending the gate records to trace.
func (g *Engine) buildTable(src string, rows []string, m Membership, trace *[]Obj) *table {
	p := g.pack
	inR := map[string]bool{}
	for _, k := range rows {
		inR[k] = true
	}

	// 1. Columns: tracks whose others (members not in R) are not empty and hold no entity of S.
	t := &table{rows: rows}
	var others [][]string
	for _, name := range m.order() {
		var o []string
		ok := true
		for _, k := range m.Systems[name] {
			if inR[k] {
				continue
			}
			if g.entities[k].Source == src {
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
		a := g.entities[ak]
		own := m.systemOf(ak)
		row := make([]entry, len(t.cols)+1)
		for j, name := range t.cols {
			pass := true
			for _, bk := range others[j] {
				if !g.runTests("gate", p.Gate, a, g.entities[bk], trace) {
					pass = false
					break
				}
			}
			if pass {
				c := g.cost(a, others[j])
				if own == name {
					c -= p.KeepBonus
				}
				row[j] = entry{c, true}
			}
		}
		alone := p.NewCost
		if own != "" && len(m.Systems[own]) == 1 {
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
				out = append(out, assignRecord(ak, t.chosenName(j), "cost", e.cost, true))
			} else {
				out = append(out, assignRecord(ak, t.chosenName(j), "cost", nil, false))
			}
		}
	}
	return out
}

// assignment is one choice per row: an index into the row's entries, the
// number of columns meaning alone. That is also its choice vector (Ranking).
type assignment struct {
	choice []int
	total  float64
}

// totalOf is the sum of the chosen entries in ascending order of value, added
// left to right from 0 (Ranking).
func (t *table) totalOf(choice []int) float64 {
	vals := make([]float64, len(choice))
	for i, j := range choice {
		vals[i] = t.entries[i][j].cost
	}
	sort.Float64s(vals)
	sum := 0.0
	for _, v := range vals {
		sum = sum + v
	}
	return sum
}

// ranked returns the first k assignments in the Ranking order: total ascending,
// equal totals by the smaller choice vector. Every assignment is enumerated in
// choice-vector order (rows in key order, columns in creation order, alone
// last), then a stable sort by total keeps that order among equal totals.
func (t *table) ranked(k int) []assignment {
	n, m := len(t.rows), len(t.cols)
	var all []assignment
	choice := make([]int, n)
	used := make([]bool, m)
	var rec func(i int)
	rec = func(i int) {
		if i == n {
			c := append([]int(nil), choice...)
			all = append(all, assignment{c, t.totalOf(c)})
			return
		}
		for j := 0; j <= m; j++ {
			if !t.entries[i][j].ok || (j < m && used[j]) {
				continue
			}
			choice[i] = j
			if j < m {
				used[j] = true
			}
			rec(i + 1)
			if j < m {
				used[j] = false
			}
		}
	}
	rec(0)
	sort.SliceStable(all, func(a, b int) bool { return all[a].total < all[b].total })
	if len(all) > k {
		all = all[:k]
	}
	return all
}

// apply applies an assignment to membership m, rows in key order (step 4).
func (t *table) apply(m *Membership, a assignment, events []Obj) []Obj {
	for i, ak := range t.rows {
		own := m.systemOf(ak)
		if a.choice[i] < len(t.cols) {
			name := t.cols[a.choice[i]]
			if own == name {
				continue
			}
			if own != "" {
				events = m.leave(ak, "assign", events)
			}
			events = m.join(ak, name, events)
			continue
		}
		if own != "" && len(m.Systems[own]) == 1 {
			continue // alone already
		}
		if own != "" {
			events = m.leave(ak, "assign", events)
		}
		events = m.start(ak, events)
	}
	return events
}

func assignRecord(a, b, test string, value any, pass bool) Obj {
	return Obj{"stage": "assign", "a": a, "b": b, "test": test, "value": value, "limit": nil, "pass": pass}
}

func historyRecord(a, b any, test string, value float64, pass bool) Obj {
	return Obj{"stage": "history", "a": a, "b": b, "test": test, "value": value, "limit": nil, "pass": pass}
}

// tag adds the given keys to each record, only with a window above 1 (spec: Trace).
func (g *Engine) tag(recs []Obj, kv ...any) []Obj {
	if g.pack.Window > 1 {
		for _, r := range recs {
			for i := 0; i < len(kv); i += 2 {
				r[kv[i].(string)] = kv[i+1]
			}
		}
	}
	return recs
}

// ---------------------------------------------------------------------------
// Window (spec: Window, On each tick)

// candidate is one ranked assignment r applied to history h.
type candidate struct {
	h, r  int
	hist  History
	total float64
}

// tickAssign runs one tick, steps 1 to 6 of Window.
func (g *Engine) tickAssign(now int64) (events, trace []Obj) {
	events, trace = []Obj{}, []Obj{}
	p := g.pack
	windowed := p.Window > 1

	// 1. Staleness: every history gets a new record with the stale entities dropped.
	var stale []string
	for _, k := range sortedKeys(g.entities) {
		if e := g.entities[k]; !e.Retiring && g.isStale(e, now) {
			stale = append(stale, k)
		}
	}
	isStale := map[string]bool{}
	for _, k := range stale {
		isStale[k] = true
	}
	var restarted []string
	for _, k := range sortedKeys(g.restarted) {
		if !isStale[k] {
			restarted = append(restarted, k)
		}
	}
	for i, h := range g.histories {
		rec := Record{Choices: []Choice{}, Events: []Obj{}, M: h.latest(g.committed).copy()}
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
		g.histories[i] = History{append(append([]Record(nil), h.Records...), rec)}
	}
	for _, k := range stale {
		g.entities[k].Retiring = true
		delete(g.reported, k)
	}
	g.restarted = map[string]bool{} // no entity is restarted after this step

	// 2. Rows: entities reported since the previous tick, grouped by source.
	bySource := map[string][]string{}
	rows := map[string]bool{}
	for _, k := range sortedKeys(g.reported) {
		src := g.entities[k].Source
		bySource[src] = append(bySource[src], k)
		rows[k] = true
	}
	g.reported = map[string]bool{}

	// 3. Sources, in key order: each history's ranked assignments become candidates.
	for _, src := range sortedKeys(bySource) {
		rows := bySource[src]
		var cands []candidate
		for hi, h := range g.histories {
			last := h.Records[len(h.Records)-1]
			var gates []Obj
			t := g.buildTable(src, rows, last.M, &gates)
			trace = append(trace, g.tag(gates, "h", hi)...)
			trace = append(trace, g.tag(t.costRecords(), "h", hi)...)
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
					choices = append(choices, assignRecord(ak, chosen, "choice", t.entries[i][a.choice[i]].cost, true))
				}
				trace = append(trace, g.tag(choices, "h", hi, "r", ri)...)
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
		g.histories = g.histories[:0:0]
		for i, c := range cands {
			kept := i < int(p.Hypotheses)
			if p.HasMargin {
				kept = kept && c.total <= cut.(float64)
			}
			if kept {
				g.histories = append(g.histories, c.hist)
			}
			if windowed {
				rec := historyRecord(c.h, c.r, "total", c.total, kept)
				rec["limit"] = cut
				trace = append(trace, rec)
			}
		}
	}

	// 4. Commit, when the best history has n records.
	if int64(len(g.histories[0].Records)) == p.Window {
		best := g.histories[0].Records[0]
		var kept []History
		for i, h := range g.histories {
			keep := sameChoices(h.Records[0].Choices, best.Choices)
			if windowed {
				trace = append(trace, historyRecord(i, nil, "commit", h.total(), keep))
			}
			if keep {
				kept = append(kept, History{append([]Record(nil), h.Records[1:]...)})
			}
		}
		g.histories = kept
		events = append(events, best.Events...)
		g.committed = best.M
		for _, ev := range best.Events {
			if ev["ev"] == "drop" {
				delete(g.entities, ev["entity"].(string))
			}
		}
		for k, e := range g.entities {
			e.System = g.committed.systemOf(k)
		}
	}

	// 5. Bias: the update of Sensor bias, over the committed membership.
	if p.HasBias {
		trace = append(trace, g.updateBias(now, rows)...)
	}

	// 6. Output: the committed system tracks (with margin, the best history's
	// latest ones), then the best history's provisional ones.
	best := g.histories[0].latest(g.committed)
	reported := g.committed
	if p.HasMargin {
		reported = best
	}
	for _, name := range reported.order() {
		events = append(events, g.systemEvent(name, reported.Systems[name], now))
	}
	if windowed {
		m := best
		for _, name := range m.order() {
			events = append(events, Obj{"ev": "provisional", "system": name, "members": strList(m.Systems[name])})
		}
	}
	return events, trace
}

// systemEvent is the fused estimate of all a system track's members at now (step 6).
func (g *Engine) systemEvent(name string, members []string, now int64) Obj {
	fe, fn := g.fused(members, now, nil)
	lat, lon := g.toDegrees(fe.P, fn.P)
	course := deg(math.Atan2(fe.V, fn.V))
	if course < 0 {
		course += 360
	}
	if course >= 360 {
		course -= 360
	}
	ev := Obj{"ev": "system", "system": name, "members": strList(members),
		"lat": lat, "lon": lon, "course": course, "speed_ms": math.Hypot(fe.V, fn.V)}
	var src *Entity
	for _, k := range members { // key order: a tie keeps the earlier
		e := g.entities[k]
		if _, ok := e.num("hae"); ok && (src == nil || e.LastTime > src.LastTime) {
			src = e
		}
	}
	if src != nil {
		ev["hae"], _ = src.num("hae")
	}
	return ev
}

// ---------------------------------------------------------------------------
// Snapshot (spec: Snapshot)

func systemsObj(m Membership) Obj {
	out := Obj{}
	for k, v := range m.Systems {
		out[k] = strList(v)
	}
	return out
}

func (g *Engine) snapshotAssign() Obj {
	var ref any
	if g.ref != nil {
		ref = []any{g.ref[0], g.ref[1]}
	}
	ents := Obj{}
	for k, e := range g.entities {
		var sys any
		if e.System != "" {
			sys = e.System
		}
		ents[k] = e.filterSnapshot(Obj{"last_time_ms": e.LastTime, "system": sys})
	}
	snap := Obj{"ref": ref, "entities": ents, "systems": systemsObj(g.committed),
		"next_system": int64(g.committed.Next), "reported": strList(sortedKeys(g.reported))}
	if g.pack.HasRestart {
		snap["restarted"] = strList(sortedKeys(g.restarted))
	}
	if g.pack.HasBias {
		snap["bias"] = g.biasSnapshot()
	}
	if g.pack.Window == 1 {
		return snap
	}
	retiring := []any{}
	for _, k := range sortedKeys(g.entities) {
		if g.entities[k].Retiring {
			retiring = append(retiring, k)
		}
	}
	histories := []any{}
	for _, h := range g.histories {
		records := []any{}
		for _, r := range h.Records {
			choices := []any{}
			for _, c := range r.Choices {
				choices = append(choices, []any{c.Entity, c.Chosen})
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
