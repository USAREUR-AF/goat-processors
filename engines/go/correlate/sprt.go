package correlate

import (
	"strings"

	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// The sequential test (spec/correlate.md 1.0: Association, Sequential
// test): with the sprt line, each pair holds L, the log-likelihood ratio of
// "same object" against "different objects", in place of the counts, the
// hold tests and hold_failures.

// evidence is one report's evidence for A against B predicted to A's time:
// the increment of L and the record's d2.
func (g *Engine) evidence(a, b *Entity) (inc, d2 float64) {
	sp := g.pack.Sprt
	posVar, velVar := sp.PosM*sp.PosM, sp.VelMs*sp.VelMs
	e, n := g.pairOf(a, b).State()
	inc = e.SprtIncrement(posVar, velVar) + n.SprtIncrement(posVar, velVar)
	d2 = e.Q + n.Q
	if dh, ok := (Pair{A: a, B: b}).haeDiff(); ok {
		hInc, hD2 := model.SprtHaeIncrement(dh, sp.HaeSigmaM, posVar)
		inc, d2 = inc+hInc, d2+hD2
	}
	return inc, d2
}

// sprtUpdate updates the pair of A and B, from L (0 when the pair has
// none): with forced, L = lo; otherwise L plus A's evidence, clamped to
// [lo, up]. It writes the sprt record and returns the new L and up.
func (g *Engine) sprtUpdate(a, b *Entity, l float64, forced bool, tr *[]Obj) (float64, float64) {
	up, lo := model.SprtBounds(g.pack.Sprt.False, g.pack.Sprt.Missed)
	var inc, d2 any
	if forced {
		l = lo
	} else {
		i, d := g.evidence(a, b)
		l = min(max(l+i, lo), up)
		inc, d2 = i, d
	}
	rec := trace.Record("sprt", a.Key, b.Key, "llr", l, up, l >= up)
	rec["lower"], rec["increment"], rec["d2"] = lo, inc, d2
	*tr = append(*tr, rec)
	g.llr[pairKey(a.Key, b.Key)] = l
	return l, up
}

// sameTests are the same tests of the gate line, in pack order.
func (g *Engine) sameTests() []Test {
	var out []Test
	for _, t := range g.pack.Gate {
		if t.Name == "same" {
			out = append(out, t)
		}
	}
	return out
}

// sprtCandidate updates the pair of an ungrouped A and candidate B after
// their gate and confirm tests (ok: every test passed), and reports whether
// the pair is ready (L at up).
func (g *Engine) sprtCandidate(a, b *Entity, ok bool, tr *[]Obj) bool {
	pk := pairKey(a.Key, b.Key)
	l, has := g.llr[pk]
	forced := false
	if !ok {
		if !has {
			return false
		}
		// The same tests run again, without trace records.
		forced = !g.runTests("gate", g.sameTests(), a, b, &[]Obj{})
	}
	l, up := g.sprtUpdate(a, b, l, forced, tr)
	_, lo := model.SprtBounds(g.pack.Sprt.False, g.pack.Sprt.Missed)
	if l <= lo {
		delete(g.llr, pk)
		return false
	}
	return l >= up
}

// sprtGroup updates the link pair of A in its group and releases A when
// its L falls to lo.
func (g *Engine) sprtGroup(a *Entity, events []Obj, tr *[]Obj) []Obj {
	var link *Entity
	best := 0.0
	for _, bk := range g.groups[a.Group] {
		if bk == a.Key {
			continue
		}
		l := g.llr[pairKey(a.Key, bk)] // a pair with no L reads 0
		if link == nil || l > best {
			link, best = g.entities[bk], l
		}
	}
	forced := !g.runTests("gate", g.sameTests(), a, link, tr)
	l, _ := g.sprtUpdate(a, link, best, forced, tr)
	_, lo := model.SprtBounds(g.pack.Sprt.False, g.pack.Sprt.Missed)
	if l > lo {
		return events
	}
	events = g.leave(a, "release", events)
	for pk, pl := range g.llr {
		if pl <= lo && pairNames(pk, a.Key) {
			delete(g.llr, pk)
		}
	}
	return events
}

// pairNames reports whether pair key pk names entity k.
func pairNames(pk, k string) bool {
	a, b, _ := strings.Cut(pk, "|")
	return a == k || b == k
}
