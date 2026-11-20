package fuse

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/snapshot"
)

// Snapshot returns the whole state (Snapshot).
func (g *Engine) Snapshot() Obj {
	entities := Obj{}
	for k, e := range g.entities {
		entities[k] = Obj{
			"last_time_ms": e.LastTime,
			"group":        model.OrNull(e.Group),
			"filter":       snapshot.Filter(model.Model{East: e.East, North: e.North}),
			"report":       e.Report,
		}
	}
	return Obj{"ref": snapshot.Ref(g.frame), "entities": entities}
}

// Restore returns an engine for p in the state of a snapshot, as Snapshot
// returns it or as JSON decodes it (numbers as json.Number): it continues
// exactly as the engine that took the snapshot. An entity's source is its
// report's track.source_id.
func Restore(p *Pack, snap map[string]any) (*Engine, error) {
	var d snapshot.Decoder
	g := New(p)
	g.frame = d.Ref(snap["ref"])
	for key, v := range d.Object("entities", snap["entities"]) {
		o := d.Object(key, v)
		f := d.Filter("filter", o["filter"])
		report := d.Object("report", o["report"])
		e := &Entity{Key: key, Source: d.String("track.source_id", report["track.source_id"]),
			LastTime: d.Int("last_time_ms", o["last_time_ms"]), East: f.East, North: f.North, Report: report}
		if grp := o["group"]; grp != nil {
			e.Group = d.String("group", grp)
		}
		g.entities[key] = e
	}
	if d.Err != nil {
		return nil, d.Err
	}
	return g, nil
}
