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

// Restore returns an engine for p in the state of a snapshot, as Snapshot
// returns it or as JSON decodes it (numbers as json.Number): it continues
// exactly as the engine that took the snapshot.
func Restore(p *Pack, snap map[string]any) (*Engine, error) {
	var d snapshot.Decoder
	g := New(p)
	for key, v := range d.Object("entities", snap["entities"]) {
		o := d.Object(key, v)
		g.entities[key] = &State{
			TimeMs: d.Int("time_ms", o["time_ms"]), Lat: d.Float("lat", o["lat"]), Lon: d.Float("lon", o["lon"]),
			Course: d.OptFloat("course", o["course"]), SpeedMs: d.OptFloat("speed_ms", o["speed_ms"]),
			StaleMs: d.OptInt("stale_ms", o["stale_ms"]), KeptMs: d.OptInt("kept_ms", o["kept_ms"]),
		}
	}
	if d.Err != nil {
		return nil, d.Err
	}
	return g, nil
}
