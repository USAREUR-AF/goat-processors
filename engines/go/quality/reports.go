package quality

import (
	"goat-correlator/engines/go/model"
)

// reading is what quality reads from one report (spec: Reports). An optional
// key that is null, of the wrong type, or a ce of 0 or below is absent.
type reading struct {
	source, key         string
	t                   int64
	lat, lon            float64
	ce                  float64 // valid ce, or default_ce_m
	hasCe               bool
	course, speed       float64
	hasCourse, hasSpeed bool
	hasHae              bool
	received            int64
	hasReceived         bool
}

// read checks the required keys in table order and reads the optional ones.
// It returns the missing required key, or "".
func (g *Engine) read(report map[string]any) (reading, string) {
	var r reading
	if k := model.MissingKey(report); k != "" {
		return r, k
	}
	r.source = report["track.source_id"].(string)
	r.key = r.source + "/" + report["uid"].(string)
	r.t, _ = model.ToInt(report["time_ms"])
	r.lat, _ = model.ToFloat(report["lat"])
	r.lon, _ = model.ToFloat(report["lon"])

	r.ce, r.hasCe = model.ToFloat(report["ce"])
	if !r.hasCe || r.ce <= 0 {
		r.ce, r.hasCe = g.pack.DefaultCeM, false
	}
	r.course, r.hasCourse = model.ToFloat(report["course"])
	r.speed, r.hasSpeed = model.ToFloat(report["speed_ms"])
	_, r.hasHae = model.ToFloat(report["hae"])
	if model.IsInt(report["received_ms"]) {
		r.received, _ = model.ToInt(report["received_ms"])
		r.hasReceived = true
	}
	return r, ""
}
