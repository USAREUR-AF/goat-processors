package correlate

import (
	"goat-correlator/engines/go/assign"
	"goat-correlator/engines/go/model"
)

// The assign row of the method table: package assign, which reads this
// engine's entities through assign.Core.

type assignMethod struct{ m *assign.Method }

func newAssign(g *Engine) method {
	p := g.pack
	return assignMethod{assign.New(core{g}, assign.Params{
		NewCost: p.NewCost, KeepBonus: p.KeepBonus, Window: p.Window, Hypotheses: p.Hypotheses,
		HasMargin: p.HasMargin, Margin: p.Margin,
		HasBias: p.HasBias, BiasSigma: p.BiasSigma, BiasFloor: p.BiasFloor, BiasGate: p.BiasGate,
		HasTimeOffset: p.HasTimeOffset, TimeOffsetSigmaMs: p.TimeOffsetSigmaMs,
		HasRestart: p.HasRestart,
	})}
}

func (a assignMethod) reject(e *Entity) string {
	if a.m.Retiring(e.Key) {
		return "retiring" // correlate-assign.md: Window, Reports for a retiring entity
	}
	return ""
}
func (a assignMethod) restarted(key string) { a.m.Restarted(key) }
func (a assignMethod) ingested(e *Entity, events []Obj, _ *[]Obj) []Obj {
	a.m.Reported(e.Key) // assignment happens on the tick (correlate-assign.md Events)
	return events
}
func (a assignMethod) tick(now int64) (events, trace []Obj) { return a.m.Tick(now) }
func (a assignMethod) snapshot() Obj                        { return a.m.Snapshot() }
func (a assignMethod) moveInto(bSource, aSource string, be, bn model.Axis) (model.Axis, model.Axis) {
	return a.m.MoveInto(bSource, aSource, be, bn)
}

// core is the engine as assign.Core.
type core struct{ g *Engine }

func (c core) Keys() []string                 { return model.SortedKeys(c.g.entities) }
func (c core) Source(k string) string         { return c.g.entities[k].Source }
func (c core) LastTime(k string) int64        { return c.g.entities[k].LastTime }
func (c core) Stale(k string, now int64) bool { return c.g.isStale(c.g.entities[k], now) }
func (c core) Drop(k string)                  { delete(c.g.entities, k) }
func (c core) Frame() *model.Frame            { return c.g.ref }
func (c core) Filter(k string) (model.Axis, model.Axis) {
	e := c.g.entities[k]
	return e.East, e.North
}
func (c core) Predicted(k string, t int64) (model.Axis, model.Axis) {
	return c.g.predicted(c.g.entities[k], t)
}
func (c core) TimingVariance(k string) (float64, float64) {
	e := c.g.entities[k]
	return e.TimeVarEast, e.TimeVarNorth
}
func (c core) Hae(k string) (float64, bool) { return c.g.entities[k].num("hae") }
func (c core) Gate(a, b string, trace *[]Obj) bool {
	return c.g.runTests("gate", c.g.pack.Gate, c.g.entities[a], c.g.entities[b], trace)
}
func (c core) Intervals() (Obj, bool) { return c.g.intervalsSnapshot() }
func (c core) EntitySnapshot(k string, out Obj) Obj {
	e := c.g.entities[k]
	out["last_time_ms"] = e.LastTime
	return e.filterSnapshot(out)
}
