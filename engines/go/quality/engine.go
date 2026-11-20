package quality

import (
	"goat-correlator/engines/go/model"
)

// Obj is one event, trace record or snapshot map.
type Obj = model.Obj

// Orders of a report (spec: Order).
const (
	orderFirst      = "first"
	orderAdvance    = "advance"
	orderDuplicate  = "duplicate"
	orderOutOfOrder = "out-of-order"
)

// record is one accepted report in an entity's window (spec: Samples).
// A nil sample was not taken.
type record struct {
	wt, timeMs        int64
	order             string
	interval, latency *int64
	lateness          any // int64, float64 (clock a mean of two values), or nil
	timeError         *float64
	timeState         *string
	stateCode         int64 // the time state's code, when timeState is not nil
	sourceOutOfOrder  bool
	nis, speedErr     *float64
	ce, vel, hae      bool // presence flags
}

// entity is one track (spec: Frame and filter, Snapshot).
type entity struct {
	key, source string
	last        int64      // latest accepted time (of a first or advance report)
	lastPos     [2]float64 // plane position of that report, as reported
	east, north model.Axis
	window      []record // arrival order
}

// ruleState is a rule's state for one subject (spec: Rules).
type ruleState struct {
	count  int64
	active bool
}

// Engine is one quality stage (spec: What quality does).
type Engine struct {
	pack     *Pack
	ref      *model.Frame
	lastTick *int64
	entities map[string]*entity
	// states[i] holds pack.Rules[i]'s state per subject (entity key or source).
	states []map[string]*ruleState
	// scratch is the Window the measures are read from, reused at each
	// entity of each tick; it holds no state between them.
	scratch Window
}

// New returns an engine for a loaded pack.
func New(p *Pack) *Engine {
	g := &Engine{pack: p, entities: map[string]*entity{}}
	for range p.Rules {
		g.states = append(g.states, map[string]*ruleState{})
	}
	return g
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
