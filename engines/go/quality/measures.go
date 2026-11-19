package quality

// dropOld drops the records with wt <= now_ms - window_ms, keeping arrival
// order (spec: Window).
func (e *entity) dropOld(now, windowMs int64) {
	kept := e.window[:0]
	for _, rec := range e.window {
		if rec.wt > now-windowMs {
			kept = append(kept, rec)
		}
	}
	e.window = kept
}

// mean is s / n, s starting at 0.0 and adding each value in order in binary64
// (spec: Entity measures).
func mean(xs []float64) float64 {
	s := 0.0
	for _, x := range xs {
		s += x
	}
	return s / float64(len(xs))
}

func maxInt(xs []int64) int64 {
	m := xs[0]
	for _, x := range xs[1:] {
		if x > m {
			m = x
		}
	}
	return m
}

func toFloats(xs []int64) []float64 {
	out := make([]float64, len(xs))
	for i, x := range xs {
		out[i] = float64(x)
	}
	return out
}

// measures computes an entity's measures over its window at now_ms
// (spec: Entity measures). An absent measure is nil.
func (g *Engine) measures(e *entity, now int64) Obj {
	k := int(g.pack.MinSamples)
	var intervals, latencies []int64
	var nis, speedErr []float64
	var outOfOrder, duplicate, noCe, noVel, noHae int64
	for _, rec := range e.window {
		if rec.interval != nil {
			intervals = append(intervals, *rec.interval)
		}
		if rec.latency != nil {
			latencies = append(latencies, *rec.latency)
		}
		if rec.nis != nil {
			nis = append(nis, *rec.nis)
		}
		if rec.speedErr != nil {
			speedErr = append(speedErr, *rec.speedErr)
		}
		switch rec.order {
		case orderOutOfOrder:
			outOfOrder++
		case orderDuplicate:
			duplicate++
		}
		if !rec.ce {
			noCe++
		}
		if !rec.vel {
			noVel++
		}
		if !rec.hae {
			noHae++
		}
	}
	reports := int64(len(e.window))
	m := Obj{
		"reports":        reports,
		"interval_last":  nil,
		"interval_mean":  nil,
		"interval_max":   nil,
		"age":            now - e.last,
		"latency_mean":   nil,
		"latency_max":    nil,
		"nis_mean":       nil,
		"speed_err_mean": nil,
		"out_of_order":   outOfOrder,
		"duplicate":      duplicate,
		"missing_ce":     nil,
		"missing_vel":    nil,
		"missing_hae":    nil,
	}
	// A statistic is absent when fewer than min_samples records hold its sample.
	if len(intervals) >= k {
		m["interval_last"] = intervals[len(intervals)-1]
		m["interval_mean"] = mean(toFloats(intervals))
		m["interval_max"] = maxInt(intervals)
	}
	if len(latencies) >= k {
		m["latency_mean"] = mean(toFloats(latencies))
		m["latency_max"] = maxInt(latencies)
	}
	if len(nis) >= k {
		m["nis_mean"] = mean(nis)
	}
	if len(speedErr) >= k {
		m["speed_err_mean"] = mean(speedErr)
	}
	if reports >= int64(k) {
		m["missing_ce"] = float64(noCe) / float64(reports)
		m["missing_vel"] = float64(noVel) / float64(reports)
		m["missing_hae"] = float64(noHae) / float64(reports)
	}
	return m
}

// sourceMeasuresOf aggregates the measures of a source's entities, given in
// entity key order (spec: Source measures).
func sourceMeasuresOf(entities []Obj) Obj {
	m := Obj{"entities": int64(len(entities))}

	// Sums, always present.
	for _, name := range []string{"reports", "out_of_order", "duplicate"} {
		var s int64
		for _, em := range entities {
			s += em[name].(int64)
		}
		m[name] = s
	}

	// Mean over entities of the present values, in key order; null when none.
	for _, name := range []string{"interval_last", "interval_mean", "latency_mean", "nis_mean",
		"speed_err_mean", "missing_ce", "missing_vel", "missing_hae"} {
		var present []float64
		for _, em := range entities {
			if v, ok := asFloat(em[name]); ok {
				present = append(present, v)
			}
		}
		m[name] = nil
		if len(present) > 0 {
			m[name] = mean(present)
		}
	}

	// Largest present value; null when none.
	for _, name := range []string{"interval_max", "latency_max"} {
		var present []int64
		for _, em := range entities {
			if v, ok := em[name].(int64); ok {
				present = append(present, v)
			}
		}
		m[name] = nil
		if len(present) > 0 {
			m[name] = maxInt(present)
		}
	}

	// Smallest age: the freshest entity.
	age := entities[0]["age"].(int64)
	for _, em := range entities[1:] {
		if a := em["age"].(int64); a < age {
			age = a
		}
	}
	m["age"] = age
	return m
}

// asFloat reads a measure value as binary64; false when it is absent.
func asFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case int64:
		return float64(x), true
	case float64:
		return x, true
	}
	return 0, false
}
