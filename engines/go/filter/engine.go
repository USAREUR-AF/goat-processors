package filter

import (
	"goat-correlator/engines/go/model"
)

// Obj is one event, trace record or snapshot map.
type Obj = model.Obj

// State is the stored state of one entity (spec: Snapshot, Rules step 4).
type State struct {
	TimeMs   int64
	Lat, Lon float64
	Course   *float64 // nil = null
	SpeedMs  *float64
	StaleMs  *int64
	KeptMs   *int64 // nil until a report of the entity is kept
}

// Engine runs one pack.
type Engine struct {
	pack     *Pack
	entities map[string]*State
}

// New returns an engine for a loaded pack, with no state.
func New(p *Pack) *Engine {
	return &Engine{pack: p, entities: map[string]*State{}}
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
