package correlate

import (
	"fmt"

	"goat-correlator/engines/go/model"
)

// The correlate methods, the pack's `method` line (spec: correlate.md
// Association for confirm, correlate-assign.md for assign). Adding a method
// is one entry here: its pack directives, its checks and its constructor.

// method is what a correlate method does on top of the shared engine
// (reports, frame, filter, restart, tests).
type method interface {
	// reject gives the reason a report of an existing entity is refused
	// before anything else is done with it, or "".
	reject(e *Entity) string
	// restarted is called when an entity's filter started again (Restart).
	restarted(key string)
	// ingested runs the method on an accepted report of e.
	ingested(e *Entity, events []model.Obj, trace *[]model.Obj) []model.Obj
	// tick runs one tick.
	tick(now int64) (events, trace []model.Obj)
	// snapshot is the whole state.
	snapshot() model.Obj
	// moveInto moves B's prediction into A's frame (Sensor bias); a method
	// without bias returns it unchanged.
	moveInto(bSource, aSource string, be, bn model.Axis) (model.Axis, model.Axis)
}

// methodSpec is one row of the method table.
type methodSpec struct {
	required []string          // directives the pack must have
	refused  []string          // directives the pack must not have
	check    func(*Pack) error // value ranges of the method's own directives
	new      func(g *Engine) method
}

var methods = map[string]methodSpec{
	"confirm": {
		required: []string{"pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"},
		refused:  []string{"new_cost", "keep_bonus", "window", "hypotheses", "margin", "bias", "time_offset"},
		new:      func(g *Engine) method { return confirmMethod{g} },
	},
	"assign": {
		required: []string{"pack", "version", "method", "filter", "new_cost", "keep_bonus", "stale_ms"},
		refused:  []string{"confirm", "hold", "confirm_count", "hold_failures", "same_source", "output", "priority"},
		check: func(p *Pack) error {
			if !(p.NewCost > 0 && p.KeepBonus >= 0) {
				return fmt.Errorf("new_cost must be above 0 and keep_bonus 0 or above")
			}
			return nil
		},
		new: newAssign,
	},
}
