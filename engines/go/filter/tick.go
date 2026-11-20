package filter

import (
	"goat-correlator/engines/go/model"
	"goat-correlator/engines/go/trace"
)

// Tick forgets entities that have not reported for longer than forget_ms
// (spec: Tick).
func (g *Engine) Tick(now int64) (events, tr []Obj) {
	events, tr = []Obj{}, []Obj{}
	for _, key := range model.SortedKeys(g.entities) {
		age := now - g.entities[key].TimeMs
		forget := age > g.pack.ForgetMs
		tr = append(tr, trace.Forget(key, age, g.pack.ForgetMs, forget))
		if forget {
			delete(g.entities, key)
			events = append(events, Obj{"ev": "forget", "entity": key})
		}
	}
	return events, tr
}
