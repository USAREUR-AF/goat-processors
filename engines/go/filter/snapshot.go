package filter

import (
	"goat-correlator/engines/go/snapshot"
)

// Snapshot returns the whole state (spec: Snapshot).
func (g *Engine) Snapshot() Obj {
	ents := Obj{}
	for key, s := range g.entities {
		ents[key] = Obj{"time_ms": s.TimeMs, "lat": s.Lat, "lon": s.Lon,
			"course": snapshot.OptFloat(s.Course), "speed_ms": snapshot.OptFloat(s.SpeedMs),
			"stale_ms": snapshot.OptInt(s.StaleMs), "kept_ms": snapshot.OptInt(s.KeptMs)}
	}
	return Obj{"entities": ents}
}
