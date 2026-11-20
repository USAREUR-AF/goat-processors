package correlate

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// restartTest runs the restart test of correlate.md Restart for a later
// report at time t, appending its trace record, and reports whether the
// report may update the filter (true also when the pack has no restart line).
func (g *Engine) restartTest(e *Entity, t int64, z model.Measurement, tr *[]Obj) bool {
	p := g.pack
	if !p.HasRestart {
		return true
	}
	pe, pn := g.predicted(e, t)
	// z.REast, z.RNorth are the report's measurement variance (Track
	// estimate), found from this same prediction's velocity; no timing
	// variance is added to the prediction here.
	d2 := model.Mahalanobis(z.East, z.North, pe, pn, z.REast, z.RNorth)
	pass := d2 < p.RestartGate
	*tr = append(*tr, trace.Restart(e.Key, d2, p.RestartGate, pass))
	return pass
}
