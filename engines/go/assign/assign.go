// Package assign is method assign of spec/correlate-assign.md (version 0.7):
// system tracks, per-source ranked assignments at each tick, kept as up to
// k histories over a window of n ticks, sensor bias and the clock offset,
// and the inverse-variance fused estimate.
//
// The method reads the correlate engine's entities only through Core, so
// this package does not depend on package correlate; correlate's method
// table creates it (correlate/assign.go).
//
// Files by section of correlate-assign.md: membership.go (Memberships),
// table.go (Assignment of one source: columns, entries, cost; Fused
// estimate), ranking.go (Ranking), window.go (Window, On each tick, Events),
// bias.go (Sensor bias, Time offset), snapshot.go (Snapshot).
package assign

import (
	"goat-correlator/engines/go/model"
)

// Obj is one event, trace record or snapshot map.
type Obj = model.Obj

// Core is what method assign reads and changes of the correlate engine's
// entities, each named by its key.
type Core interface {
	Keys() []string // every entity key, in key order
	Source(k string) string
	LastTime(k string) int64
	Filter(k string) (east, north model.Axis)             // the entity's filter
	Predicted(k string, t int64) (east, north model.Axis) // its prediction to t
	TimingVariance(k string) (east, north float64)        // its last timing variance
	Hae(k string) (float64, bool)                         // its last report's hae
	Stale(k string, now int64) bool                       // correlate.md On each tick, Staleness
	Gate(a, b string, trace *[]Obj) bool                  // the pack's gate tests, A against B
	Drop(k string)                                        // removes the entity
	Frame() *model.Frame                                  // the reference, nil before the first report
	EntitySnapshot(k string, out Obj) Obj                 // adds last_time_ms and the filter fields
	Intervals() (Obj, bool)                               // with stale_rate, the snapshot's intervals
}

// Params are the pack directives of method assign (correlate-assign.md Pack).
type Params struct {
	NewCost, KeepBonus float64
	Window, Hypotheses int64 // n, k
	HasMargin          bool
	Margin             float64 // m
	HasBias            bool
	BiasSigma          float64 // s
	BiasFloor          float64 // f
	BiasGate           float64 // g
	HasTimeOffset      bool
	TimeOffsetSigmaMs  float64 // t
	HasRestart         bool
}

// Method is the state of method assign.
type Method struct {
	core      Core
	p         Params
	committed Membership            // the membership the output reports
	histories []History             // in rank order
	reported  map[string]bool       // entities with an accepted report since the previous tick
	restarted map[string]bool       // entities whose filter started again since the previous tick (correlate.md Restart)
	retiring  map[string]bool       // entities found stale, drop not yet committed
	system    map[string]string     // each entity's committed system track, set at each commit
	bias      map[string]*BiasState // pair key "<S>|<T>" -> stored offset (Sensor bias)
}

// New returns method assign over core's entities.
func New(core Core, p Params) *Method {
	return &Method{core: core, p: p, committed: newMembership(), histories: []History{{}},
		reported: map[string]bool{}, restarted: map[string]bool{}, retiring: map[string]bool{},
		system: map[string]string{}, bias: map[string]*BiasState{}}
}

// Retiring reports whether entity k is retiring: its reports are rejected
// (Window, Reports for a retiring entity).
func (m *Method) Retiring(k string) bool { return m.retiring[k] }

// Reported records an accepted report of k; assignment happens on the tick (Events).
func (m *Method) Reported(k string) { m.reported[k] = true }

// Restarted records that k's filter started again, until the next tick (Window step 1).
func (m *Method) Restarted(k string) { m.restarted[k] = true }
