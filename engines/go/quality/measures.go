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

// extreme returns the largest (largest true) or smallest present value of
// numbers that are int64 or float64, compared as binary64; the first one on
// a tie, in its own type.
func extreme(xs []any, largest bool) any {
	best := xs[0]
	b, _ := asFloat(best)
	for _, x := range xs[1:] {
		v, _ := asFloat(x)
		if (largest && v > b) || (!largest && v < b) {
			best, b = x, v
		}
	}
	return best
}

func toFloats(xs []int64) []float64 {
	out := make([]float64, len(xs))
	for i, x := range xs {
		out[i] = float64(x)
	}
	return out
}

// The measures tables (spec: Entity measures, Source measures) are one
// table, DefaultMeasures: each measure's name, its value from an entity's
// window, and how a source aggregates it over its entities. Adding a
// measure is one row (and, for a new kind of sample, a field of Window).

// Window is what one entity's window holds, for the measures: each sample's
// values in arrival order, the counts, and the entity's age at now_ms.
type Window struct {
	Reports    int64 // records in the window
	Age        int64 // now_ms - the entity's latest time
	MinSamples int   // k = min_samples: a statistic over fewer is absent

	Intervals, Latencies  []int64
	Lateness              []any // int64 or float64
	NIS, SpeedErr         []float64
	TimeErrors            []float64
	StateCodes            []int64
	OutOfOrder, Duplicate int64
	SourceOutOfOrder      int64
	NoCe, NoVel, NoHae    int64
	NoTime                int64
}

// windowOf reads an entity's window records in one pass.
func windowOf(records []record, age int64, k int) *Window {
	w := &Window{Reports: int64(len(records)), Age: age, MinSamples: k}
	for _, rec := range records {
		if rec.interval != nil {
			w.Intervals = append(w.Intervals, *rec.interval)
		}
		if rec.latency != nil {
			w.Latencies = append(w.Latencies, *rec.latency)
		}
		if rec.lateness != nil {
			w.Lateness = append(w.Lateness, rec.lateness)
		}
		if rec.nis != nil {
			w.NIS = append(w.NIS, *rec.nis)
		}
		if rec.speedErr != nil {
			w.SpeedErr = append(w.SpeedErr, *rec.speedErr)
		}
		if rec.timeError != nil {
			w.TimeErrors = append(w.TimeErrors, *rec.timeError)
		}
		if rec.timeState != nil {
			w.StateCodes = append(w.StateCodes, timeStateCodes[*rec.timeState])
		} else {
			w.NoTime++
		}
		if rec.sourceOutOfOrder {
			w.SourceOutOfOrder++
		}
		switch rec.order {
		case orderOutOfOrder:
			w.OutOfOrder++
		case orderDuplicate:
			w.Duplicate++
		}
		if !rec.ce {
			w.NoCe++
		}
		if !rec.vel {
			w.NoVel++
		}
		if !rec.hae {
			w.NoHae++
		}
	}
	return w
}

// Aggregate is how a source measure is found from its entities' values,
// taken in entity key order (spec: Source measures).
type Aggregate int

const (
	Sum      Aggregate = iota // the sum, always present (integers)
	Mean                      // the mean of the present values; null when none
	Largest                   // the largest present value; null when none
	Smallest                  // the smallest present value; null when none
	Freshest                  // the smallest value, always present (age)
	Count                     // the number of entities (source only)
)

// Measure is one row of the measures tables.
type Measure struct {
	Name   string
	Entity func(w *Window) any // the entity measure, nil when absent; nil func for a source-only measure
	Source Aggregate
}

// enough reports whether n samples make a statistic present.
func (w *Window) enough(n int) bool { return n >= w.MinSamples }

// ratio is n / reports when the window holds at least k records.
func (w *Window) ratio(n int64) any {
	if w.Reports < int64(w.MinSamples) {
		return nil
	}
	return float64(n) / float64(w.Reports)
}

// DefaultMeasures is the measures table of spec/quality.md, in table order:
// a new slice at each call, so a caller may add a row to its own copy
// (Registry).
func DefaultMeasures() []Measure {
	return []Measure{
		{"reports", func(w *Window) any { return w.Reports }, Sum},
		{"interval_last", func(w *Window) any {
			if !w.enough(len(w.Intervals)) {
				return nil
			}
			return w.Intervals[len(w.Intervals)-1]
		}, Mean},
		{"interval_mean", func(w *Window) any {
			if !w.enough(len(w.Intervals)) {
				return nil
			}
			return mean(toFloats(w.Intervals))
		}, Mean},
		{"interval_max", func(w *Window) any {
			if !w.enough(len(w.Intervals)) {
				return nil
			}
			return maxInt(w.Intervals)
		}, Largest},
		{"age", func(w *Window) any { return w.Age }, Freshest},
		{"latency_mean", func(w *Window) any {
			if !w.enough(len(w.Latencies)) {
				return nil
			}
			return mean(toFloats(w.Latencies))
		}, Mean},
		{"latency_max", func(w *Window) any {
			if !w.enough(len(w.Latencies)) {
				return nil
			}
			return maxInt(w.Latencies)
		}, Largest},
		{"lateness_mean", func(w *Window) any {
			if !w.enough(len(w.Lateness)) {
				return nil
			}
			values := make([]float64, len(w.Lateness))
			for i, x := range w.Lateness {
				values[i], _ = asFloat(x)
			}
			return mean(values)
		}, Mean},
		{"lateness_max", func(w *Window) any {
			if !w.enough(len(w.Lateness)) {
				return nil
			}
			return extreme(w.Lateness, true)
		}, Largest},
		{"lateness_min", func(w *Window) any {
			if !w.enough(len(w.Lateness)) {
				return nil
			}
			return extreme(w.Lateness, false)
		}, Smallest},
		{"nis_mean", func(w *Window) any {
			if !w.enough(len(w.NIS)) {
				return nil
			}
			return mean(w.NIS)
		}, Mean},
		{"speed_err_mean", func(w *Window) any {
			if !w.enough(len(w.SpeedErr)) {
				return nil
			}
			return mean(w.SpeedErr)
		}, Mean},
		{"out_of_order", func(w *Window) any { return w.OutOfOrder }, Sum},
		{"duplicate", func(w *Window) any { return w.Duplicate }, Sum},
		{"source_out_of_order", func(w *Window) any { return w.SourceOutOfOrder }, Sum},
		{"missing_ce", func(w *Window) any { return w.ratio(w.NoCe) }, Mean},
		{"missing_vel", func(w *Window) any { return w.ratio(w.NoVel) }, Mean},
		{"missing_hae", func(w *Window) any { return w.ratio(w.NoHae) }, Mean},
		{"time_error_mean", func(w *Window) any {
			if !w.enough(len(w.TimeErrors)) {
				return nil
			}
			return mean(w.TimeErrors)
		}, Mean},
		{"time_error_max", func(w *Window) any {
			if !w.enough(len(w.TimeErrors)) {
				return nil
			}
			largest := w.TimeErrors[0]
			for _, x := range w.TimeErrors[1:] {
				if x > largest {
					largest = x
				}
			}
			return largest
		}, Largest},
		{"time_state_last", func(w *Window) any {
			if !w.enough(len(w.StateCodes)) {
				return nil
			}
			return w.StateCodes[len(w.StateCodes)-1]
		}, Largest},
		{"time_state_worst", func(w *Window) any {
			if !w.enough(len(w.StateCodes)) {
				return nil
			}
			return maxInt(w.StateCodes)
		}, Largest},
		{"missing_time", func(w *Window) any { return w.ratio(w.NoTime) }, Mean},
		{"entities", nil, Count},
	}
}

// measures computes an entity's measures over its window at now_ms
// (spec: Entity measures). An absent measure is nil.
func (g *Engine) measures(e *entity, now int64) Obj {
	return entityMeasuresOf(g.pack.Measures, windowOf(e.window, now-e.last, int(g.pack.MinSamples)))
}

// entityMeasuresOf is every entity measure of the table over one window.
func entityMeasuresOf(table []Measure, w *Window) Obj {
	m := make(Obj, len(table))
	for _, ms := range table {
		if ms.Entity != nil {
			m[ms.Name] = ms.Entity(w)
		}
	}
	return m
}

// sourceMeasuresOf aggregates the measures of a source's entities, given in
// entity key order (spec: Source measures).
func sourceMeasuresOf(table []Measure, entities []Obj) Obj {
	m := make(Obj, len(table))
	for _, ms := range table {
		m[ms.Name] = aggregate(ms.Source, ms.Name, entities)
	}
	return m
}

// aggregate is one source measure from its entities' values.
func aggregate(how Aggregate, name string, entities []Obj) any {
	switch how {
	case Count:
		return int64(len(entities))
	case Sum:
		var s int64
		for _, em := range entities {
			s += em[name].(int64)
		}
		return s
	case Mean:
		var present []float64
		for _, em := range entities {
			if v, ok := asFloat(em[name]); ok {
				present = append(present, v)
			}
		}
		if len(present) == 0 {
			return nil
		}
		return mean(present)
	case Largest, Smallest:
		var present []any
		for _, em := range entities {
			if v := em[name]; v != nil {
				present = append(present, v)
			}
		}
		if len(present) == 0 {
			return nil
		}
		return extreme(present, how == Largest)
	case Freshest:
		age := entities[0][name].(int64)
		for _, em := range entities[1:] {
			if a := em[name].(int64); a < age {
				age = a
			}
		}
		return age
	}
	panic("unknown aggregate")
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
