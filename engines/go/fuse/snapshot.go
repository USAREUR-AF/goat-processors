package fuse

import (
	"goat-correlator/engines/go/model"
)

// Snapshot returns the whole state (Snapshot).
func (g *Engine) Snapshot() Obj {
	var ref any
	if g.frame != nil {
		ref = []any{g.frame.Lat0, g.frame.Lon0}
	}
	entities := Obj{}
	for k, e := range g.entities {
		entities[k] = Obj{
			"last_time_ms": e.LastTime,
			"group":        model.OrNull(e.Group),
			"filter":       Obj{"east": e.East.List(), "north": e.North.List()},
			"report":       e.Report,
		}
	}
	return Obj{"ref": ref, "entities": entities}
}
