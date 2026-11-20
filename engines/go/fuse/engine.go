// Package fuse is the Go engine of spec/fuse.md (version 0.2): it combines the
// reports of the entities named into one group by `fuse.group` into one fused
// estimate per group at each tick.
//
// The per-entity filter, the frame and the report checks are the correlate
// engine's own (package model), as spec/fuse.md "Shared with correlate.md"
// requires. Section names in comments refer to spec/fuse.md unless they say
// otherwise.
package fuse

import (
	"goat-correlator/engines/go/model"
)

// Obj is one event, trace record or snapshot map.
type Obj = model.Obj

// Axis is one axis of the correlate filter: p, v, pp, pv, vv.
type Axis = model.Axis

// Entity is one source's track.
type Entity struct {
	Key         string
	Source      string
	LastTime    int64
	East, North Axis
	Group       string         // the fuse.group of the last accepted report; "" for none
	Report      map[string]any // the last normalized report
}

// predicted returns copies of both axes predicted to t (correlate.md: Track
// estimate, prediction; dt may be negative).
func (e *Entity) predicted(t int64, q float64) (Axis, Axis) {
	dt := float64(t-e.LastTime) / 1000
	return e.East.Predict(dt, q), e.North.Predict(dt, q)
}

// Engine is one fuse engine (What fuse does: load_pack, ingest, tick, snapshot).
type Engine struct {
	pack     *Pack
	frame    *model.Frame // nil until the first accepted report
	entities map[string]*Entity
}

// New returns an engine for a loaded pack.
func New(p *Pack) *Engine {
	return &Engine{pack: p, entities: map[string]*Entity{}}
}

var _ model.Engine = (*Engine)(nil)

// Load loads the pack in dir and returns a new engine for it.
func Load(dir string) (*Engine, error) {
	p, err := LoadPack(dir)
	if err != nil {
		return nil, err
	}
	return New(p), nil
}
