package fuse

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Kinematics: each method gives, per axis, p, v, pp, vv, and the member they came
// from (nil for inverse_variance and covariance_intersection). East and north are
// computed by the same formulas, east first.

// kinematicsMethod is one row of the kinematics table: from a group's
// predicted members, in key order, the result per axis, the member it came
// from (nil for a combination) and, for covariance_intersection, the
// weight of each fold.
type kinematicsMethod func(g *Engine, members []member) (east, north Axis, from *member, folds []float64)

// kinematicsMethods is the kinematics table (Kinematics); adding a method is
// one row.
var kinematicsMethods = map[string]kinematicsMethod{
	"inverse_variance": func(_ *Engine, members []member) (Axis, Axis, *member, []float64) {
		e, n := inverseVariance(members)
		return e, n, nil, nil
	},
	"covariance_intersection": func(_ *Engine, members []member) (Axis, Axis, *member, []float64) {
		e, n, folds := covarianceIntersection(members)
		return e, n, nil, folds
	},
	"best": pickBy(func(_ *Engine, m, w member) bool { return m.variance() < w.variance() }),
	"priority": pickBy(func(g *Engine, m, w member) bool {
		return g.rankOrder(m.Entity) < g.rankOrder(w.Entity)
	}),
	"latest": pickBy(func(_ *Engine, m, w member) bool { return m.LastTime > w.LastTime }),
}

// pickBy is a method that takes one member's filter: the first, in key
// order, that no later member beats (best, priority, latest).
func pickBy(better func(g *Engine, m, w member) bool) kinematicsMethod {
	return func(g *Engine, members []member) (Axis, Axis, *member, []float64) {
		from := pick(members, func(m, w member) bool { return better(g, m, w) })
		return from.east, from.north, from, nil
	}
}

// kinematics combines the predicted members of a group by the pack's method and
// appends the intersect records (covariance_intersection) and the kinematics
// record (Trace, items 1 and 2).
func (g *Engine) kinematics(name string, members []member, tr *[]Obj) (east, north Axis, from *member) {
	method := g.pack.Kinematics
	east, north, from, folds := kinematicsMethods[method](g, members)
	for i, w := range folds {
		*tr = append(*tr, trace.Intersect(model.OrNull(name), members[i+1].Key, w))
	}

	candidates := make([]any, len(members))
	for i, m := range members {
		candidates[i] = trace.KinematicsCandidate(m.Key, m.variance(), m.LastTime, g.rank(m.Entity))
	}
	var winner any
	if from != nil {
		winner = from.Key
	}
	*tr = append(*tr, trace.Kinematics(model.OrNull(name), method, candidates, winner))
	return east, north, from
}

// pick returns the first member, in key order, that no later member beats:
// better(m, w) is true when m strictly beats the current winner w, so ties stay
// with the earlier member (best, priority, latest: ties to key order).
func pick(members []member, better func(m, w member) bool) *member {
	w := &members[0]
	for i := 1; i < len(members); i++ {
		if better(members[i], *w) {
			w = &members[i]
		}
	}
	return w
}

// inverseVariance is the method inverse_variance, members in key order.
func inverseVariance(members []member) (Axis, Axis) {
	axis := func(get func(member) Axis) Axis {
		var ip, sp, iv, sv float64
		for _, m := range members {
			a := get(m)
			ip = ip + 1/a.PP
			sp = sp + a.P/a.PP
			iv = iv + 1/a.VV
			sv = sv + a.V/a.VV
		}
		pp := 1 / ip
		vv := 1 / iv
		return Axis{P: pp * sp, V: vv * sv, PP: pp, VV: vv}
	}
	return axis(func(m member) Axis { return m.east }), axis(func(m member) Axis { return m.north })
}

// covarianceIntersection is the method covariance_intersection: the running
// estimate X starts as the first member, and each later member Y is folded in,
// in key order, with the closed-form weight. It also returns the weight of
// each fold, members[1:] in order: one intersect record each.
func covarianceIntersection(members []member) (Axis, Axis, []float64) {
	xe, xn := members[0].east, members[0].north
	weights := make([]float64, 0, len(members)-1)
	for _, y := range members[1:] {
		w := ciWeight(xe, xn, y.east, y.north)
		weights = append(weights, w)
		switch w {
		case 1: // X unchanged
		case 0:
			xe, xn = y.east, y.north
		default:
			xe, xn = ciFold(xe, y.east, w), ciFold(xn, y.north, w)
		}
	}
	return xe, xn, weights
}

// ciWeight is covariance_intersection, Weight, steps 1 to 5.
func ciWeight(xe, xn, ye, yn Axis) float64 {
	ae, an := 1/ye.PP, 1/yn.PP       // 1
	de, dn := 1/xe.PP-ae, 1/xn.PP-an // 2
	c2 := de * dn                    // 3
	c1 := ae*dn + an*de              // 4
	// 5
	if c2 < 0 {
		w := -c1 / (2 * c2)
		if w < 0 {
			w = 0
		}
		if w > 1 {
			w = 1
		}
		return w
	}
	switch s := c1 + c2; {
	case s > 0:
		return 1
	case s < 0:
		return 0
	default:
		return 0.5
	}
}

// ciFold is covariance_intersection, Fold, on one axis, with 0 < w < 1.
func ciFold(x, y Axis, w float64) Axis {
	a := w / x.PP
	b := (1 - w) / y.PP
	pp := 1 / (a + b)
	p := pp * (a*x.P + b*y.P)
	c := w / x.VV
	d := (1 - w) / y.VV
	vv := 1 / (c + d)
	v := vv * (c*x.V + d*y.V)
	return Axis{P: p, V: v, PP: pp, VV: vv}
}

// rank is the rank for a trace record: the index of the source, or nil when unlisted.
func (g *Engine) rank(e *Entity) any {
	if r := g.pack.Rank(e.Source); r >= 0 {
		return int64(r)
	}
	return nil
}

// rankOrder is the rank for comparison: an unlisted source ranks after every listed one.
func (g *Engine) rankOrder(e *Entity) int {
	if r := g.pack.Rank(e.Source); r >= 0 {
		return r
	}
	return len(g.pack.Sources)
}
