package assign

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Sensor bias (spec: Sensor bias): one position offset per unordered pair of
// sources, used to move one source's predictions into the other's frame,
// and learned at each tick from the committed system tracks. With the
// time_offset line each pair also has a clock offset tau, fitted with the
// position offset (Sensor bias, Time offset).

// BiasState is the stored state of one pair "<S>|<T>" (S before T in key
// order): how far T's positions sit east and north of S's.
type BiasState struct {
	OEast, WEast   float64 // offset o and weight sum w, east
	ONorth, WNorth float64 // offset o and weight sum w, north
	Var            float64 // var, both axes
	Pairs          int64   // n, the count of accepted pairs

	// With time_offset (Time offset): tau, in seconds, how far T's clock is
	// ahead of S's, and the sums S1 to S8 of the least-squares fit.
	Tau  float64
	Sums [8]float64
}

// biasState returns the state of pair key, or the state a pair with none
// reads as: o = 0, w = 0, var = s², n = 0 (State).
func (m *Method) biasState(key string) BiasState {
	if st, ok := m.bias[key]; ok {
		return *st
	}
	s := m.p.BiasSigma
	return BiasState{Var: s * s}
}

// MoveInto moves B's predicted axes into A's frame (Moving B into A's frame).
// Without the bias line, or for two entities of one source, nothing moves.
func (m *Method) MoveInto(bSource, aSource string, be, bn model.Axis) (model.Axis, model.Axis) {
	if !m.p.HasBias || aSource == bSource {
		return be, bn
	}
	key := aSource + "|" + bSource
	if bSource < aSource {
		key = bSource + "|" + aSource
	}
	return m.biasState(key).move(be, bn, bSource < aSource, m.p.HasTimeOffset)
}

// move moves B's predicted axes by the pair's offset: plus when B's source
// is the pair's first (S), minus when it is the second (T); the offset on
// each axis is o, or with time offset o - v*tau, v being B's predicted
// velocity on that axis; var is added to pp.
func (st BiasState) move(be, bn model.Axis, bFirst, withTau bool) (model.Axis, model.Axis) {
	oe, on := st.OEast, st.ONorth
	if withTau {
		oe = st.OEast - be.V*st.Tau
		on = st.ONorth - bn.V*st.Tau
	}
	if bFirst {
		be.P, be.PP = be.P+oe, be.PP+st.Var
		bn.P, bn.PP = bn.P+on, bn.PP+st.Var
	} else {
		be.P, be.PP = be.P-oe, be.PP+st.Var
		bn.P, bn.PP = bn.P-on, bn.PP+st.Var
	}
	return be, bn
}

// updateBias runs the Update of Sensor bias at now over the committed
// membership, for pairs with at least one member among the tick's rows, and
// returns its trace records.
func (m *Method) updateBias(now int64, rows map[string]bool) []Obj {
	p, c := m.p, m.core
	out := []Obj{}
	for _, name := range m.committed.order() {
		var members []string // not retiring, key order
		for _, k := range m.committed.Systems[name] {
			if !m.retiring[k] {
				members = append(members, k)
			}
		}
		for i, x := range members {
			for _, y := range members[i+1:] {
				if c.Source(x) == c.Source(y) || !(rows[x] || rows[y]) {
					continue
				}
				// 1. ES has the source first in key order; predict both to now (not moved).
				es, et := x, y
				if c.Source(et) < c.Source(es) {
					es, et = et, es
				}
				key := c.Source(es) + "|" + c.Source(et)
				se, sn := c.Predicted(es, now)
				te, tn := c.Predicted(et, now)
				st, d2, accepted := m.biasState(key).update(p, se, sn, te, tn)
				if accepted {
					m.bias[key] = &st
				}

				// 4. Trace, with the state after step 3.
				var tau any
				if p.HasTimeOffset {
					tau = st.Tau * 1000
				}
				out = append(out, trace.Bias(x, y, d2, p.BiasGate, accepted, st.OEast, st.ONorth, st.Var, st.Pairs, tau))
			}
		}
	}
	return out
}

// update is steps 2 and 3 of the Update for one pair whose members, the
// first source's (S) and the second's (T), are predicted to now (not
// moved): it returns the pair's state after them, d² and whether the pair
// was accepted (below the gate).
func (st BiasState) update(p Params, se, sn, te, tn model.Axis) (BiasState, float64, bool) {
	ye, re := te.P-se.P, se.PP+te.PP
	yn, rn := tn.P-sn.P, sn.PP+tn.PP

	// 2. d² with the pair's state; with time_offset the expected offset is
	// o - v*tau, v the mean of the two predicted velocities.
	var de, dn, ve, vn float64
	if p.HasTimeOffset {
		ve, vn = (se.V+te.V)/2, (sn.V+tn.V)/2
		de, dn = ye-(st.OEast-ve*st.Tau), yn-(st.ONorth-vn*st.Tau)
	} else {
		de, dn = ye-st.OEast, yn-st.ONorth
	}
	d2 := de*de/(st.Var+re) + dn*dn/(st.Var+rn)

	// 3. Accept below the gate.
	if !(d2 < p.BiasGate) {
		return st, d2, false
	}
	st.Pairs++
	st.Var = p.BiasSigma * p.BiasSigma / float64(st.Pairs+1)
	if floor := p.BiasFloor * p.BiasFloor; st.Var < floor {
		st.Var = floor
	}
	if p.HasTimeOffset {
		return st.fitTimeOffset(p, 1/re, 1/rn, ve, vn, ye, yn), d2, true
	}
	st.WEast = st.WEast + 1/re
	st.OEast = st.OEast + ((1/re)/st.WEast)*(ye-st.OEast)
	st.WNorth = st.WNorth + 1/rn
	st.ONorth = st.ONorth + ((1/rn)/st.WNorth)*(yn-st.ONorth)
	return st, d2, true
}

// fitTimeOffset adds one accepted pair to the sums and solves the weighted
// least-squares fit of y = o - v*tau (Sensor bias, Time offset). we, wn are
// 1/r on east and north; ve, vn the mean predicted velocities; ye, yn the
// observed offsets. n and var have already changed as in step 3.
func (st BiasState) fitTimeOffset(p Params, we, wn, ve, vn, ye, yn float64) BiasState {
	S := &st.Sums
	S[0] = S[0] + we                    // S1
	S[1] = S[1] + wn                    // S2
	S[2] = S[2] + we*ve                 // S3
	S[3] = S[3] + wn*vn                 // S4
	S[4] = S[4] + (we*ve*ve + wn*vn*vn) // S5
	S[5] = S[5] + we*ye                 // S6
	S[6] = S[6] + wn*yn                 // S7
	S[7] = S[7] + (we*ve*ye + wn*vn*yn) // S8

	po := 1 / (p.BiasSigma * p.BiasSigma)
	ts := p.TimeOffsetSigmaMs / 1000
	pt := 1 / (ts * ts)
	a11 := po + S[0]
	a22 := po + S[1]
	a13 := -S[2]
	a23 := -S[3]
	a33 := pt + S[4]
	b1 := S[5]
	b2 := S[6]
	b3 := -S[7]
	st.Tau = (b3 - a13*b1/a11 - a23*b2/a22) / (a33 - a13*a13/a11 - a23*a23/a22)
	st.OEast = (b1 - a13*st.Tau) / a11
	st.ONorth = (b2 - a23*st.Tau) / a22
	st.WEast, st.WNorth = S[0], S[1]
	return st
}
