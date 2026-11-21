package model

import "math"

// The full-state track-to-track statistic (spec/correlate.md 1.0: Tests,
// the state test) and the evidence of one report for the sequential test
// (Association, Sequential test). Pure functions of axis values.

// StateAxis is one axis of the state test: A's filter axis a with A's timing
// variance ta on that axis, against B's prediction b to A's time (with B's
// timing variance already in b.PP).
type StateAxis struct {
	DP, DV, SPP, SPV, SVV, Det, Q float64
}

// StateOf computes dp, dv, spp, spv, svv, det and q of one axis, in the
// order the specification writes them.
func StateOf(a Axis, ta float64, b Axis) StateAxis {
	dp := a.P - b.P
	dv := a.V - b.V
	spp := a.PP + ta + b.PP
	spv := a.PV + b.PV
	svv := a.VV + b.VV
	det := spp*svv - spv*spv
	q := (svv*dp*dp - 2*spv*dp*dv + spp*dv*dv) / det
	return StateAxis{dp, dv, spp, spv, svv, det, q}
}

// SprtIncrement is one axis's term of the evidence, 0.5*(q0 - q) +
// 0.5*ln(det0/det), with "different objects" spread by P (position
// variance) and V (velocity variance).
func (s StateAxis) SprtIncrement(posVar, velVar float64) float64 {
	tpp := s.SPP + posVar
	tvv := s.SVV + velVar
	det0 := tpp*tvv - s.SPV*s.SPV
	q0 := (tvv*s.DP*s.DP - 2*s.SPV*s.DP*s.DV + tpp*s.DV*s.DV) / det0
	return 0.5*(q0-s.Q) + 0.5*math.Log(det0/s.Det)
}

// SprtHaeIncrement is the height term of the evidence: h1 = 2*hs*hs,
// h0 = h1 + P; it returns the increment and dh*dh/h1.
func SprtHaeIncrement(dh, hs, posVar float64) (inc, d2 float64) {
	h1 := 2 * hs * hs
	h0 := h1 + posVar
	inc = 0.5*(dh*dh/h0-dh*dh/h1) + 0.5*math.Log(h0/h1)
	return inc, dh * dh / h1
}

// SprtBounds are up = ln((1 - missed) / false) and lo = ln(missed / (1 - false)).
func SprtBounds(falseP, missed float64) (up, lo float64) {
	return math.Log((1 - missed) / falseP), math.Log(missed / (1 - falseP))
}

// ChiSquare is the table of the state test's limits (Abramowitz and Stegun
// 1964, table 26.8): probability, then the quantile at 4 and 5 degrees of
// freedom.
var ChiSquare = [...][3]float64{
	{0.95, 9.4877, 11.0705},
	{0.99, 13.2767, 15.0863},
	{0.995, 14.8603, 16.7496},
	{0.999, 18.4668, 20.5150},
}

// ChiSquareLimit returns the quantile of probability at dof (4 or 5), and
// whether the probability is in the table.
func ChiSquareLimit(probability float64, dof int) (float64, bool) {
	for _, row := range ChiSquare {
		if row[0] == probability {
			return row[dof-3], true
		}
	}
	return 0, false
}
