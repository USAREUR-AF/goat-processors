package correlate

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Reports and Time quality (spec/correlate.md 1.0: Reports, "Time quality";
// Track estimate, "Measurement variance"; Pack, time_default): what one
// accepted report gives the filter.

// timeQuality returns a report's time error (ms) and time state, each found
// per key: the report's own key, else the pack's time_default for the
// report's source, else error 0 and state coherent. Correlate reads the time
// state but does not use it in this version.
func timeQuality(defaults map[string]model.TimeDefault, source string, report map[string]any) (float64, string) {
	te, state := 0.0, "coherent"
	def, hasDef := defaults[source]
	if v, ok := report["time_error_ms"]; ok {
		te, _ = model.ToFloat(v)
	} else if hasDef && def.HasError {
		te = def.ErrorMs
	}
	if v, ok := report["time_state"]; ok {
		state = v.(string)
	} else if hasDef && def.HasState {
		state = def.State
	}
	return te, state
}

// measure reads a cleaned report of entity e (nil for a first report) at
// time t into the filter's measurement, and returns its ce, its time error
// and its timing variance, appending the time record when the time error is
// above 0. The timing variance is found from the prediction's velocity to
// the report's time; for a first report, from the measured velocity, or 0.
func (g *Engine) measure(e *Entity, source, key string, t int64, report map[string]any, lat, lon float64,
	tr *[]Obj) (z model.Measurement, ce, te, varE, varN float64) {
	p := g.pack
	z.East, z.North = g.ref.ToPlane(lat, lon)
	ce, ok := model.ToFloat(report["ce"])
	if !ok {
		ce = p.DefaultCeM
	}
	course, hasC := model.ToFloat(report["course"])
	speed, hasS := model.ToFloat(report["speed_ms"])
	if z.HasVel = hasC && hasS; z.HasVel {
		z.VE, z.VN = model.Velocity(course, speed)
	}
	te, _ = timeQuality(p.TimeDefaults, source, report)
	ve, vn := z.VE, z.VN
	if e != nil && te != 0 {
		pe, pn := g.predicted(e, t)
		ve, vn = pe.V, pn.V
	}
	z.REast, z.RNorth, varE, varN = model.MeasurementVariance(ce, te, ve, vn)
	if te > 0 {
		*tr = append(*tr, trace.Time(key, te, varE, varN))
	}
	return z, ce, te, varE, varN
}
