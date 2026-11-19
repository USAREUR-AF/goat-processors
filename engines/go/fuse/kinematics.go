package fuse

// Kinematics: each method gives, per axis, p, v, pp, vv, and the member they came
// from (nil for inverse_variance and covariance_intersection). East and north are
// computed by the same formulas, east first.

// kinematics combines the predicted members of a group by the pack's method and
// appends the intersect records (covariance_intersection) and the kinematics
// record (Trace, items 1 and 2).
func (g *Engine) kinematics(name string, members []member, trace *[]Obj) (east, north Axis, from *member) {
	method := g.pack.Kinematics
	switch method {
	case "inverse_variance":
		east, north = inverseVariance(members)
	case "covariance_intersection":
		east, north = g.covarianceIntersection(name, members, trace)
	case "best":
		from = pick(members, func(m, w member) bool { return m.variance() < w.variance() })
	case "priority":
		from = pick(members, func(m, w member) bool { return g.rankOrder(m.Entity) < g.rankOrder(w.Entity) })
	case "latest":
		from = pick(members, func(m, w member) bool { return m.LastTime > w.LastTime })
	}
	if from != nil {
		east, north = from.east, from.north
	}

	candidates := make([]any, len(members))
	for i, m := range members {
		candidates[i] = Obj{"member": m.Key, "var": m.variance(), "time_ms": m.LastTime, "rank": g.rank(m.Entity)}
	}
	var winner any
	if from != nil {
		winner = from.Key
	}
	*trace = append(*trace, Obj{"stage": "kinematics", "group": nameOrNull(name), "method": method,
		"candidates": candidates, "winner": winner})
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
// in key order, with the closed-form weight. Each fold is one intersect record.
func (g *Engine) covarianceIntersection(name string, members []member, trace *[]Obj) (Axis, Axis) {
	xe, xn := members[0].east, members[0].north
	for _, y := range members[1:] {
		w := ciWeight(xe, xn, y.east, y.north)
		*trace = append(*trace, Obj{"stage": "intersect", "group": nameOrNull(name), "member": y.Key, "value": w})
		switch w {
		case 1: // X unchanged
		case 0:
			xe, xn = y.east, y.north
		default:
			xe, xn = ciFold(xe, y.east, w), ciFold(xn, y.north, w)
		}
	}
	return xe, xn
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
